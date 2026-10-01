import Foundation
import SwiftUI

/// llama.cpp 引擎（GGUF + Metal）。
///
/// 省内存（对应"一次对话不把整个模型跑进去"）：
///  1. mmap 惰性分页（默认开、mlock 关）→ 只把跑到的权重页调入物理内存
///  2. 独占加载 → 同一时刻只有一个模型在内存里
///  3. n_gpu_layers 按内存预算决定上 Metal 的层数
///  4. 每次生成用全新 context → KV 干净
///
/// 输出质量（修小模型"开头标点、复读、跑题、算错数"）：
///  · 按品牌拼对话模板（im_start / llama header / gemma turn）
///  · 认品牌对应的终止标记，一撞上就停
///  · 默认贪心（温度 0）+ 重复惩罚；温度/惩罚/top-p/输出长度走「高级」页
final class LlamaEngine: ObservableObject {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedId: String?
    private var nCtx: Int32 = 4096
    private var backendReady = false

    // ---- 实时统计（性能页用真实值）----
    @Published private(set) var tps: Double = 0
    @Published private(set) var ctxUsed: Int = 0
    @Published private(set) var ctxTotal: Int = 0
    @Published private(set) var metalOn: Bool = false
    @Published private(set) var metalLayers: Int = 0
    @Published private(set) var loadedSizeGB: Double = 0
    @Published private(set) var note: String = "未加载模型"

    /// 生成中：发送键变终止键
    @Published private(set) var isGenerating = false
    private var stopFlag = false
    private var rngState: UInt64 = 0x9E3779B97F4A7C15

    // ---- 采样参数（「高级」页改这里，下一次生成就用新值）----

    /// 只从 UserDefaults 读；改值请走 RMSampleStore.save()
    var sample: RMSample { RMSampleStore.load() }

    var loadedModelId: String? { loadedId }
    var isLoaded: Bool { model != nil }
    var contextWindow: Int { Int(nCtx) }

    private init() {}

    private func ensureBackend() {
        guard !backendReady else { return }
        llama_backend_init()
        backendReady = true
    }

    private func key(of s: String) -> String {
        let l = s.lowercased()
        if l.contains("llama") { return "llama" }
        if l.contains("gemma") { return "gemma" }
        return "qwen"
    }

    /// 完整多轮对话模板（⚠️ 之前把多轮历史塞进单条 user 文本里，模型会把历史当"一句话说明"
    /// 去复述/瞎接，这是输出牛头不对马嘴和乱码的主因）。统一走 turns：
    ///   turns = 之前所有轮次，末尾由调用方补上"当前这次提问"。
    private func renderChat(brand: String, system: String, turns: [(Bool, String)]) -> String {
        switch brand {
        case "llama":
            // ⚠️ Llama-3 的模板比 ChatML 严：<|eot_id|> 后面直接跟下一个 <|start_header_id|>，
            // 中间多一个换行就会让模型"没进入角色"，输出一串乱码/复读。别自作聪明加 \n。
            var s = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|>"
            for t in turns {
                let who = t.0 ? "user" : "assistant"
                s += "<|start_header_id|>\(who)<|end_header_id|>\n\n\(t.1)<|eot_id|>"
            }
            return s + "<|start_header_id|>assistant<|end_header_id|>\n"
        case "gemma":
            var s = "<bos>"
            for t in turns {
                let who = t.0 ? "user" : "assistant"
                s += "<start_of_turn>\(who)\n\(t.1)<end_of_turn>\n"
            }
            return s + "<start_of_turn>assistant\n"
        default:  // qwen / ChatML
            var s = "<|im_start|>system\n\(system)<|im_end|>\n"
            for t in turns {
                let who = t.0 ? "user" : "assistant"
                s += "<|im_start|>\(who)\n\(t.1)<|im_end|>\n"
            }
            return s + "<|im_start|>assistant\n"
        }
    }

    private func stopMarkers(brand: String) -> [String] {
        switch brand {
        case "llama": return ["<|eot_id|>", "<|endoftext|>"]
        case "gemma": return ["<end_of_turn>", "<start_of_turn>"]
        default:      return ["<|im_end|>", "<|im_start|>", "<|endoftext|>"]
        }
    }

    /// 点「终止」
    func stop() {
        guard isGenerating else { return }
        stopFlag = true
    }

    @discardableResult
    func load(modelId: String, path: String, ctxTokens: Int, gpuLayers: Int, sizeGB: Double) -> Bool {
        if loadedId == modelId, isLoaded { return true }
        unload()
        guard FileManager.default.fileExists(atPath: path) else { return false }
        ensureBackend()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = Int32(gpuLayers)

        guard let m = llama_model_load_from_file(path, mp) else { return false }
        model = m
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(ctxTokens)
        loadedId = modelId

        DispatchQueue.main.async {
            self.loadedSizeGB = sizeGB
            self.ctxTotal = ctxTokens
            self.metalOn = gpuLayers > 0
            self.metalLayers = gpuLayers
            self.ctxUsed = 0
            self.tps = 0
            self.note = gpuLayers > 0
                ? "\(modelId) 已加载 · Metal \(gpuLayers) 层"
                : "\(modelId) 已加载 · 纯 CPU"
        }
        return true
    }

    func unload() {
        if let c = ctx   { llama_free(c);       ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
        let had = loadedId
        loadedId = nil
        if let h = had {
            DispatchQueue.main.async {
                if self.loadedId == nil {
                    self.loadedSizeGB = 0
                    self.ctxUsed = 0
                    self.metalOn = false
                    self.metalLayers = 0
                    self.tps = 0
                    self.note = "已卸载 \(h)"
                }
            }
        }
    }

    private func freshContext() -> OpaquePointer? {
        guard let m = model else { return nil }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        // ⚠️ n_ubatch 必须和 n_batch 一致且够大：老版写死 512，
        // 一旦提示词 + 历史超过 512 token，llama_decode 直接失败 → 一个字都吐不出来
        let cap = UInt32(min(Int(nCtx), 2048))
        cp.n_batch  = cap
        cp.n_ubatch = cap
        return llama_init_from_model(m, cp)
    }

    /// 采样用缓冲：复用，别每 token 新建 12 万个 Float（那才是"输出长度拉满 = 点发送像没反应"的元凶）
    private var scoreBuf = [Float]()
    private var probBuf = [Float]()

    private func ensureSampleBuf(_ n: Int) {
        if scoreBuf.count < n {
            scoreBuf = [Float](repeating: 0, count: n)
            probBuf = [Float](repeating: 0, count: n)
        }
    }

    /// 采样：重复惩罚 → 温度 → top-p → 随机抽。
    /// ⚠️ 老版本每步都 `[Float](count: nVocab)` + 对全部词条排序（12 万个），
    /// 温度一高就慢到几秒出一个字。这里改成：复用缓冲 + 只留 top-K 候选（默认 512）再排序。
    private func pickToken(_ lp: UnsafePointer<Float>, nVocab: Int,
                           temp: Float, topP: Float, penalty: Float,
                           recent: [Int32]) -> Int32 {
        ensureSampleBuf(nVocab)

        // 1) 拷 logits 到复用缓冲
        for i in 0..<nVocab { scoreBuf[i] = lp[i] }

        if penalty > 0, !recent.isEmpty {
            for t in recent {
                let i = Int(t)
                guard i >= 0, i < nVocab else { continue }
                if scoreBuf[i] > 0 { scoreBuf[i] -= penalty } else { scoreBuf[i] += penalty }
            }
        }

        // 2) 贪心
        if temp <= 0.02 {
            var best: Float = -.infinity
            var bi = 0
            var found = false
            for i in 0..<nVocab {
                if !found || scoreBuf[i] > best { best = scoreBuf[i]; bi = i; found = true }
            }
            return Int32(bi)
        }

        // 3) softmax
        let inv = 1.0 / max(temp, 0.01)
        var maxV: Float = -.infinity
        for i in 0..<nVocab {
            let v = scoreBuf[i] * inv
            probBuf[i] = v
            if v > maxV { maxV = v }
        }
        var sum: Float = 0
        for i in 0..<nVocab {
            let e = expf(probBuf[i] - maxV)
            probBuf[i] = e
            sum += e
        }
        guard sum > 0 else { return Int32(0) }
        let norm = 1.0 / sum
        for i in 0..<nVocab { probBuf[i] = probBuf[i] * norm }

        // 4) 只留 top-K 候选（插入法维护一个小顶序数组），再对这 K 个排序
        let K = min(nVocab, 512)
        var candIdx = [Int](repeating: -1, count: K)
        var candVal = [Float](repeating: -.infinity, count: K)
        var filled = 0
        for i in 0..<nVocab {
            let v = probBuf[i]
            if filled < K {
                var j = filled
                candIdx[j] = i; candVal[j] = v; filled += 1
                while j > 0, candVal[j] > candVal[j - 1] {
                    candIdx.swapAt(j, j - 1); candVal.swapAt(j, j - 1); j -= 1
                }
            } else if v > candVal[K - 1] {
                candVal[K - 1] = v; candIdx[K - 1] = i
                var j = K - 1
                while j > 0, candVal[j] > candVal[j - 1] {
                    candIdx.swapAt(j, j - 1); candVal.swapAt(j, j - 1); j -= 1
                }
            }
        }
        candVal.withUnsafeMutableBufferPointer { b in
            for k in 0..<K { if candIdx[k] < 0 { candIdx[k] = k; b[k] = 0 } }
        }
        var order = Array(0..<K)
        order.sort { candVal[$0] > candVal[$1] }

        // 5) top-p 截断
        var acc: Float = 0
        var lastK = 0
        for k in order {
            acc += candVal[k]
            lastK = k
            if topP > 0, topP < 1, acc >= topP { break }
        }
        if lastK != 0 { order = Array(order.prefix(through: lastK)) }

        // 6) 随机抽
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let r = Double(rngState >> 11) / Double(UInt64(1) << 53)
        var run: Float = 0
        for k in order {
            run += candVal[k]
            if r <= Double(run) { return Int32(candIdx[k]) }
        }
        return Int32(candIdx[order[order.count - 1]])
    }

    /// 生成。模板 + 终止标记 + 采样参数 + 可打断。
    /// history 是此前多轮（(是否用户, 文本)），会自动截断到最近 6 轮。
    @discardableResult
    func generate(brandHint: String, system: String, prompt: String,
                  history: [(Bool, String)] = [],
                  onToken: ((String) -> Void)? = nil) -> String {
        guard let v = vocab, model != nil else { return "" }

        if let old = ctx { llama_free(old); ctx = nil }
        guard let c = freshContext() else { return "" }
        ctx = c
        stopFlag = false
        DispatchQueue.main.async { self.isGenerating = true }

        let brand = key(of: brandHint)
        let cap = max(Int(nCtx), 1)
        var turns = Array(history.suffix(6))

        // 提示词 + system + 历史超出窗口时，从头砍历史（保最近几轮），
        // 不然模型只看得到尾巴 → 答非所问 / 吐垃圾
        let limit = Int(Double(cap) * 0.70)
        var text = ""
        var nPrompt = 0
        while true {
            text = renderChat(brand: brand, system: system, turns: turns + [(true, prompt)])
            nPrompt = tokenCount(of: text, capTokens: cap)
            if nPrompt <= limit || turns.isEmpty { break }
            turns.removeFirst()
        }
        var pTokens = [llama_token](repeating: 0, count: cap)
        guard nPrompt > 0, nPrompt < cap else {
            DispatchQueue.main.async {
                self.isGenerating = false
                self.note = "提示词太长，模型的上下文窗口装不下（窗口 \(cap) token）"
            }
            return ""
        }
        DispatchQueue.main.async { self.ctxUsed = nPrompt }

        // 提示词分块喂（超过 batch 上限就拆成几次 decode），避免长提示词 decode 失败
        let chunk = Int32(min(nPrompt, 2048))
        var decodeOK = true
        var fed = 0
        while fed < nPrompt, decodeOK {
            let n = min(Int(chunk), nPrompt - fed)
            var batch = llama_batch_init(Int32(n), 0, 1)
            batch.n_tokens = Int32(n)
            for k in 0..<n {
                batch.token[k] = pTokens[fed + k]
                batch.pos[k] = Int32(fed + k)
                batch.n_seq_id[k] = 1
                batch.seq_id[k]![0] = 0
                batch.logits[k] = (k == n - 1) ? 1 : 0
            }
            decodeOK = llama_decode(c, batch) == 0
            llama_batch_free(batch)
            fed += n
        }
        guard decodeOK else {
            if let c = ctx { llama_free(c); ctx = nil }
            DispatchQueue.main.async {
                self.isGenerating = false
                self.note = "提示词 decode 失败：提示词太长或上下文太小（窗口 \(self.nCtx) token）"
            }
            return ""
        }

        let markers = stopMarkers(brand: brand)
        let sample = RMSampleStore.load()
        // ⚠️ 输出长度必须让位给上下文余量，否则一上来就撞到窗口边界 → 一个字都吐不出来
        let room = max(8, cap - nPrompt - 8)
        let budget = max(1, min(max(1, sample.maxTokens), room))
        var gen: [llama_token] = []
        var out = ""
        var produced = 0
        var pos = nPrompt
        let t0 = Date()

        for _ in 0..<budget {
            guard pos < cap else { break }
            if stopFlag { break }
            guard let lp = llama_get_logits_ith(c, -1) else { break }
            let nVocab = Int(llama_vocab_n_tokens(v))
            guard nVocab > 0 else { break }

            let recent = Array(gen.suffix(64))
            let next = pickToken(lp, nVocab: nVocab, temp: sample.temperature,
                                 topP: sample.topP, penalty: sample.repeatPenalty,
                                 recent: recent)
            // 标准终止判定：EOS 或任何 EOG（含 <|im_end|> / <|eot_id|> / <end_of_turn|>）
            if next == llama_vocab_eos(v) || llama_vocab_is_eog(v, next) { break }

            var buf = [CChar](repeating: 0, count: 512)
            // 最后一个参数 special=false：别把特殊标记本身吐出来，否则输出里就是一串 <|im_end|>
            let n = Int(llama_token_to_piece(v, next, &buf, Int32(buf.count), 0, false))
            gen.append(next)
            if n > 0 {
                let bytes = buf.prefix(n).map { UInt8(bitPattern: $0) }
                let piece = String(bytes: bytes, encoding: .utf8) ?? ""
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if markers.contains(where: { trimmed.contains($0) }) { break }
                out += piece
                onToken?(piece)
                produced += 1
            }

            var b = llama_batch_init(1, 0, 1)
            b.n_tokens = 1
            b.token[0] = next
            b.pos[0] = Int32(pos)
            b.n_seq_id[0] = 1
            b.seq_id[0]![0] = 0
            b.logits[0] = 1
            let rc = llama_decode(c, b)
            llama_batch_free(b)
            if rc != 0 { break }
            pos += 1
        }

        // ⚠️ 内存：生成完立刻释放 context。KV cache 是内存大头（4096 窗口能占几百 MB），
        // 留着不释放就会一轮一轮往上堆 —— 之前"疑似内存泄漏"就是这里。
        if let c = ctx { llama_free(c); ctx = nil }

        let dt = Date().timeIntervalSince(t0)
        let rate = dt > 0 ? Double(produced) / dt : 0
        let stopped = stopFlag
        let clamped = sample.maxTokens > room
        DispatchQueue.main.async {
            self.isGenerating = false
            self.ctxUsed = pos
            self.tps = rate
            self.note = stopped
                ? "已手动终止（本次 \(produced) token）"
                : (produced > 0
                    ? "本次 \(produced) token · \(String(format: "%.1f", rate)) tok/s"
                    : "没有输出（提示词或历史把上下文占满了，开短的一轮再问）")
            if clamped {
                self.note += "（输出长度受上下文余量限制到 \(budget) token）"
            }
        }
        return out
    }

    /// 数一下一段文本会变成多少 token（用来判断要不要砍历史）。失败返回 0。
    private func tokenCount(of text: String, capTokens: Int) -> Int {
        guard !text.isEmpty, let v = vocab else { return 0 }
        let n = max(capTokens, 64)
        var tmp = [llama_token](repeating: 0, count: n)
        var count = 0
        text.withCString { p in
            count = Int(llama_tokenize(v, p, Int32(text.utf8.count), &tmp, Int32(n), false, true))
        }
        return count > 0 ? count : 0
    }
}

// MARK: - 采样参数（高级页读写）

struct RMSample {
    /// 默认值 = 高级页的「发挥」预设（用户要求本次测试就按这个）
    var temperature: Float = 1.0    // 越大越发散
    var repeatPenalty: Float = 0.20 // 压复读
    var topP: Float = 0.95
    var maxTokens: Int = 768
}

/// 高级页三个预设（稳 / 均衡 / 发挥）
enum RMPreset {
    case steady, balanced, creative

    var sample: RMSample {
        switch self {
        case .steady:    return RMSample(temperature: 0.0, repeatPenalty: 0.0,  topP: 0.9,  maxTokens: 256)
        case .balanced:  return RMSample(temperature: 0.6, repeatPenalty: 0.10, topP: 0.9,  maxTokens: 512)
        case .creative:  return RMSample(temperature: 1.0, repeatPenalty: 0.20, topP: 0.95, maxTokens: 768)
        }
    }

    var name: String {
        switch self {
        case .steady: return "稳"
        case .balanced: return "均衡"
        case .creative: return "发挥"
        }
    }

    var desc: String {
        switch self {
        case .steady:    return "温度 0 · 不惩罚 · 256 token"
        case .balanced:  return "温度 0.6 · 轻度惩罚 · 512 token"
        case .creative:  return "温度 1.0 · 强惩罚 · 768 token"
        }
    }

    static var all: [RMPreset] { [.steady, .balanced, .creative] }
}

enum RMSampleStore {
    private static let key = "rymind.sampling"

    /// 没存过就给「发挥」预设（用户定的默认）
    static func load() -> RMSample {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let t = d["temp"] as? Double,
              let p = d["pen"] as? Double,
              let tp = d["topp"] as? Double,
              let mt = d["maxTokens"] as? Int else { return RMPreset.creative.sample }
        return RMSample(temperature: Float(t), repeatPenalty: Float(p), topP: Float(tp), maxTokens: mt)
    }

    static func save(_ s: RMSample) {
        UserDefaults.standard.set([
            "temp": Double(s.temperature),
            "pen": Double(s.repeatPenalty),
            "topp": Double(s.topP),
            "maxTokens": s.maxTokens
        ], forKey: key)
    }
}
