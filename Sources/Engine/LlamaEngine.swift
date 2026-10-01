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
            var s = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(system)\n\n"
            for t in turns {
                let who = t.0 ? "user" : "assistant"
                s += "<|start_header_id|>\(who)<|end_header_id|>\n\n\(t.1)<|eot_id|>\n"
            }
            return s + "<|start_header_id|>assistant<|end_header_id|>\n\n"
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
        cp.n_ctx    = UInt32(nCtx)
        cp.n_batch  = UInt32(min(512, Int(nCtx)))
        cp.n_ubatch = 512
        return llama_init_from_model(m, cp)
    }

    /// 采样：重复惩罚 → 温度 → top-p → 随机抽
    private func pickToken(_ lp: UnsafePointer<Float>, nVocab: Int,
                           temp: Float, topP: Float, penalty: Float,
                           recent: [Int32]) -> Int32 {
        var scores = [Float](repeating: 0.0, count: nVocab)
        for i in 0..<nVocab { scores[i] = lp[i] }

        if penalty > 0, !recent.isEmpty {
            for t in recent {
                let i = Int(t)
                guard i >= 0, i < nVocab, scores.indices.contains(i) else { continue }
                if scores[i] > 0 { scores[i] -= penalty } else { scores[i] += penalty }
            }
        }

        if temp <= 0.02 {
            var best: Float = -.infinity
            var bi = 0
            var found = false
            for i in 0..<nVocab {
                if !found || scores[i] > best { best = scores[i]; bi = i; found = true }
            }
            return Int32(bi)
        }

        var maxV: Float = -.infinity
        for i in 0..<nVocab { if scores[i] > maxV { maxV = scores[i] } }
        var sum: Float = 0
        var probs = [Float](repeating: 0.0, count: nVocab)
        for i in 0..<nVocab {
            let e = expf((scores[i] - maxV) / temp)
            probs[i] = e
            sum += e
        }
        guard sum > 0 else { return Int32(0) }
        for i in 0..<nVocab { probs[i] = probs[i] / sum }

        var idx = Array(0..<nVocab)
        idx.sort { probs[$0] > probs[$1] }
        if topP > 0, topP < 1, let first = idx.first {
            var acc: Float = 0
            var last = first
            for i in idx {
                acc += probs[i]
                last = i
                if acc >= topP { break }
            }
            if last != first { idx = Array(idx.prefix(through: last)) }
        }

        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let r = Double(rngState >> 11) / Double(UInt64(1) << 53)
        var acc: Float = 0
        for i in idx {
            acc += probs[i]
            if r <= Double(acc) { return Int32(i) }
        }
        if let last = idx.last { return Int32(last) }
        return Int32(0)
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
        // 历史 + 本次提问，整体拼成规范多轮对话再一次性 tokenize
        let turns = Array(history.suffix(6)) + [(true, prompt)]
        let text = renderChat(brand: brand, system: system, turns: turns)
        let cap = max(Int(nCtx), 1)
        var pTokens = [llama_token](repeating: 0, count: cap)

        var nPrompt = 0
        text.withCString { p in
            nPrompt = Int(llama_tokenize(v, p, Int32(text.utf8.count), &pTokens, Int32(cap), false, true))
        }
        guard nPrompt > 0, nPrompt < cap else {
            DispatchQueue.main.async { self.isGenerating = false }
            return ""
        }
        DispatchQueue.main.async { self.ctxUsed = nPrompt }

        var batch = llama_batch_init(Int32(nPrompt), 0, 1)
        batch.n_tokens = Int32(nPrompt)
        for i in 0..<nPrompt {
            batch.token[i] = pTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (i == nPrompt - 1) ? 1 : 0
        }
        let ok = llama_decode(c, batch) == 0
        llama_batch_free(batch)
        guard ok else {
            DispatchQueue.main.async { self.isGenerating = false }
            return ""
        }

        let markers = stopMarkers(brand: brand)
        let sample = RMSampleStore.load()
        let budget = max(1, sample.maxTokens)
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

        let dt = Date().timeIntervalSince(t0)
        let rate = dt > 0 ? Double(produced) / dt : 0
        let stopped = stopFlag
        DispatchQueue.main.async {
            self.isGenerating = false
            self.ctxUsed = pos
            self.tps = rate
            self.note = stopped
                ? "已手动终止（本次 \(produced) token）"
                : (produced > 0
                    ? "本次 \(produced) token · \(String(format: "%.1f", rate)) tok/s"
                    : "没有输出")
        }
        return out
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
