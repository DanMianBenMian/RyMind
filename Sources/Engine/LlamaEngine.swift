import Foundation
import SwiftUI

/// llama.cpp 引擎（GGUF + Metal）。
///
/// 省内存的手段（对应"一次对话不把整个模型跑进去"）：
///  1. mmap 惰性分页（llama_model_params 默认 mmap 开、mlock 关）→ 只把跑到的权重页调入物理内存
///  2. 独占加载 → 同一时刻只有一个模型在内存里，切模型前先 unload
///  3. n_gpu_layers 按内存预算决定上 Metal 的层数
///  4. 每次生成用全新 context → KV 干净
///
/// 输出质量（修 Qwen 之类小模型"开头标点、复读、跑题"三大毛病）：
///  · 按品牌拼 **对话模板**（im_start / llama header / gemma turn），而不是把问题裸喂进去
///  · 认 **品牌对应的终止标记**（<|im_end|> / <|eot_id|> / <end_of_turn|>），一撞上就停
///  · 贪心 + **重复惩罚**（最近 8 个 token 打 0.45 折、24 个打 0.72 折、更早 0.9 折）
final class LlamaEngine: ObservableObject {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?    // llama_model *
    private var ctx: OpaquePointer?      // llama_context *
    private var vocab: OpaquePointer?    // const llama_vocab *
    private var loadedId: String?
    private var nCtx: Int32 = 4096
    private var backendReady = false

    // ---- 实时统计（性能页直接用真实值，不再是示例值）----
    @Published private(set) var tps: Double = 0
    @Published private(set) var ctxUsed: Int = 0
    @Published private(set) var ctxTotal: Int = 0
    @Published private(set) var metalOn: Bool = false
    @Published private(set) var metalLayers: Int = 0
    @Published private(set) var loadedSizeGB: Double = 0
    @Published private(set) var note: String = "未加载模型"

    var loadedModelId: String? { loadedId }
    var isLoaded: Bool { model != nil }

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

    private func template(brand: String, system: String, user: String) -> String {
        switch brand {
        case "llama":
            return "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(system)\n\n<|start_header_id|>user<|end_header_id|>\n\n\(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
        case "gemma":
            return "<bos><start_of_turn>system\n\(system)\n<end_of_turn>\n<start_of_turn>user\n\(user)<end_of_turn>\n<start_of_turn>assistant\n"
        default:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
    }

    private func stopMarkers(brand: String) -> [String] {
        switch brand {
        case "llama": return ["<|eot_id|>", "<|endoftext|>"]
        case "gemma": return ["<end_of_turn>", "<start_of_turn>"]
        default:      return ["<|im_end|>", "<|im_start|>", "<|endoftext|>"]
        }
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

        let brand = key(of: modelId)
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
        _ = brand
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

    /// 生成。会按品牌拼好对话模板、认终止标记、加重复惩罚。
    @discardableResult
    func generate(brandHint: String, system: String, prompt: String,
                  maxTokens: Int = 256, onToken: ((String) -> Void)? = nil) -> String {
        guard let v = vocab, model != nil else { return "" }

        if let old = ctx { llama_free(old); ctx = nil }
        guard let c = freshContext() else { return "" }
        ctx = c

        let brand = key(of: brandHint)
        let text = template(brand: brand, system: system, user: prompt)
        let cap = max(Int(nCtx), 1)
        var pTokens = [llama_token](repeating: 0, count: cap)

        var nPrompt = 0
        text.withCString { p in
            nPrompt = Int(llama_tokenize(v, p, Int32(text.utf8.count), &pTokens, Int32(cap), false, true))
        }
        guard nPrompt > 0, nPrompt < cap else { return "" }
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
        guard ok else { return "" }

        let markers = stopMarkers(brand: brand)
        var gen: [llama_token] = []
        var out = ""
        var produced = 0
        var pos = nPrompt
        let t0 = Date()

        for _ in 0..<maxTokens {
            guard pos < cap else { break }
            guard let lp = llama_get_logits_ith(c, -1) else { break }
            let nVocab = Int(llama_vocab_n_tokens(v))

            var pen: [Float]?
            if gen.count >= 8 {
                pen = [Float](repeating: 1.0, count: nVocab)
                for (i, t) in gen.enumerated() {
                    let idx = Int(t)
                    guard idx > 0, idx < nVocab else { continue }
                    let back = gen.count - i
                    pen![idx] = back <= 8 ? 0.45 : (back <= 24 ? 0.72 : 0.9)
                }
            }

            var best: llama_token = 0
            var bestVal: Float = -.infinity
            for i in 0..<nVocab {
                let score = pen == nil ? lp[i] : lp[i] * pen![i]
                if score > bestVal { bestVal = score; best = llama_token(i) }
            }
            if best == llama_vocab_eos(v) { break }

            var buf = [CChar](repeating: 0, count: 512)
            let n = Int(llama_token_to_piece(v, best, &buf, Int32(buf.count), 0, true))
            gen.append(best)
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
            b.token[0] = best
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
        let used = pos
        let rate = dt > 0 ? Double(produced) / dt : 0
        DispatchQueue.main.async {
            self.ctxUsed = used
            self.tps = rate
            self.note = produced > 0
                ? "本次 \(produced) token · \(String(format: "%.1f", rate)) tok/s"
                : "没有输出"
        }
        return out
    }
}
