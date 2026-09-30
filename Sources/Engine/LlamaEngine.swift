import Foundation

/// llama.cpp 引擎（GGUF + Metal）。
///
/// 省内存的手段（对应"一次对话不把整个模型跑进去"）：
///  1. mmap 惰性分页（llama_model_params 默认 use_mmap = true、use_mlock = false）
///     → 只把真正跑到的权重页调进物理内存；不锁页，没跑到的部分可被系统回收
///  2. 独占加载 → 同一时刻只有一个模型在内存里，切模型前先 unload 释放
///  3. n_gpu_layers 按内存预算决定上 Metal 的层数，预算小就少上
///  4. 每次生成用全新 context → KV 干净，且不依赖已改名的 llama_kv_cache_clear
final class LlamaEngine {
    static let shared = LlamaEngine()

    private var model: OpaquePointer?    // llama_model *
    private var ctx: OpaquePointer?      // llama_context *
    private var vocab: OpaquePointer?    // const llama_vocab *
    private var loadedId: String?
    private var nCtx: Int32 = 4096
    private var nGpuLayers: Int32 = 0
    private var backendReady = false

    private(set) var loadedSizeGB: Double = 0
    private(set) var activeTokens: Int = 0

    var loadedModelId: String? { loadedId }
    var isLoaded: Bool { model != nil }

    private init() {}

    private func ensureBackend() {
        guard !backendReady else { return }
        llama_backend_init()
        backendReady = true
    }

    @discardableResult
    func load(modelId: String, path: String, ctxTokens: Int, gpuLayers: Int, sizeGB: Double) -> Bool {
        if loadedId == modelId && isLoaded { return true }
        unload()   // 独占：换模型前必须释放旧的，避免两个模型同时占内存
        guard FileManager.default.fileExists(atPath: path) else { return false }
        ensureBackend()

        var mp = llama_model_default_params()
        mp.n_gpu_layers = Int32(gpuLayers)
        // use_mmap / use_mlock 在新版已不在 model_params 里；
        // 默认行为就是 mmap 载入 + 不锁页——正是我们要的"按需分页、可回收"。

        guard let m = llama_model_load_from_file(path, mp) else { return false }
        model = m
        vocab = llama_model_get_vocab(m)
        nCtx = Int32(ctxTokens)
        nGpuLayers = Int32(gpuLayers)
        loadedId = modelId
        loadedSizeGB = sizeGB
        return true
    }

    func unload() {
        if let c = ctx   { llama_free(c);       ctx = nil }
        if let m = model { llama_model_free(m); model = nil }
        vocab = nil
        loadedId = nil
        loadedSizeGB = 0
        activeTokens = 0
    }

    private func freshContext() -> OpaquePointer? {
        guard let m = model else { return nil }
        var cp = llama_context_default_params()
        cp.n_ctx    = UInt32(nCtx)
        cp.n_batch  = UInt32(min(512, Int(nCtx)))
        cp.n_ubatch = 512
        return llama_init_from_model(m, cp)
    }

    /// greedy 生成（避开 sampler API，直接对 logits 取 argmax，少一个版本依赖）
    @discardableResult
    func generate(prompt: String, maxTokens: Int = 256, onToken: ((String) -> Void)? = nil) -> String {
        guard let v = vocab, model != nil else { return "" }

        if let old = ctx { llama_free(old); ctx = nil }
        guard let c = freshContext() else { return "" }
        ctx = c

        let cap = max(Int(nCtx), 1)
        var pTokens = [llama_token](repeating: 0, count: cap)
        let nPrompt = Int(llama_tokenize(v, prompt, Int32(prompt.utf8.count), &pTokens, Int32(cap), true, false))
        guard nPrompt > 0 else { return "" }
        activeTokens = nPrompt

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

        var out = ""
        var pos = nPrompt

        for _ in 0..<maxTokens {
            guard pos < cap else { break }
            guard let logits = llama_get_logits_ith(c, -1) else { break }

            let nVocab = Int(llama_vocab_n_tokens(v))
            var best: llama_token = 0
            var bestVal: Float = -.infinity
            for i in 0..<nVocab {
                let val = logits[i]
                if val > bestVal { bestVal = val; best = llama_token(i) }
            }
            if best == llama_vocab_eos(v) { break }

            var buf = [CChar](repeating: 0, count: 512)
            let n = Int(llama_token_to_piece(v, best, &buf, Int32(buf.count), 0, true))
            if n > 0 {
                let bytes = buf.prefix(n).map { UInt8(bitPattern: $0) }
                let piece = String(bytes: bytes, encoding: .utf8) ?? ""
                out += piece
                onToken?(piece)
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
            activeTokens = pos
        }
        return out
    }
}
