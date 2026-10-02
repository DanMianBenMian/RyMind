import Foundation
import UIKit

/// stable-diffusion.cpp 引擎封装（真模型生图：GGUF 权重 + Metal，本地推理）。
///
/// 内存纪律（iPad 10 只有 4GB RAM，钉死）：
///  · 调 generate() 前**必须**先 LlamaEngine.shared.unload() —— 聊天模型和扩散模型不能同时进内存；
///    聊天模型是发送时按需自动加载的，所以卸载完全安全，回对话页发一句就自动回来。
///  · 权重走 mmap（ggml 默认），按页调入；VAE 开 tiling 分块解码，峰值再砍一大截。
///  · 上下文只建一次、换模型文件才重建；点「停止」走 sd_cancel_generation（C 库内部安全取消）。
final class RMSDEngine {

    static let shared = RMSDEngine()

    private var ctx: OpaquePointer?
    private var loadedPath: String?
    /// 同一时刻只允许一张图在生成（串行队列兜底）
    private let queue = DispatchQueue(label: "rmind.sd.serial", qos: .userInitiated)
    private let lock = NSLock()

    private init() {
        // stable-diffusion.cpp 的进度回调是**全局单槽位**，注册一次、路由到当前活跃任务
        sd_set_progress_callback(Self.cProgress, nil)
    }

    var isLoaded: Bool { ctx != nil }

    func cancel() {
        guard let ctx else { return }
        sd_cancel_generation(ctx, SD_CANCEL_ALL)
    }

    func unload() {
        lock.lock(); defer { lock.unlock() }
        if let c = ctx { free_sd_ctx(c); ctx = nil }
        loadedPath = nil
    }

    // MARK: - 进度回调（C 全局回调 → 静态路由 → 主线程）

    fileprivate static var activeStep: ((Int, Int) -> Void)?

    private static let cProgress: @convention(c) (Int32, Int32, Float, UnsafeMutableRawPointer?) -> Void = { step, steps, _, _ in
        let s = Int(step), n = Int(steps)
        guard n > 0 else { return }
        DispatchQueue.main.async { activeStep?(s, n) }
    }

    // MARK: - 生成

    /// 文生图 / 图生图（reference 非空时自动走 img2img，strength 固定 0.65）。
    /// onProgress(0…1, 文案) 与 onDone(图, 错误信息) 都回主线程。
    func generate(modelPath: String, prompt: String, negative: String,
                  reference: UIImage?, size: Int, steps: Int, cfg: Float, seed: UInt64,
                  onProgress: @escaping (Double, String) -> Void,
                  onDone: @escaping (UIImage?, String) -> Void) {
        queue.async {
            self._generate(modelPath: modelPath, prompt: prompt, negative: negative,
                           reference: reference, size: size, steps: steps, cfg: cfg, seed: seed,
                           onProgress: onProgress, onDone: onDone)
        }
    }

    private func _generate(modelPath: String, prompt: String, negative: String,
                           reference: UIImage?, size: Int, steps: Int, cfg: Float, seed: UInt64,
                           onProgress: @escaping (Double, String) -> Void,
                           onDone: @escaping (UIImage?, String) -> Void) {
        DispatchQueue.main.async { onProgress(0.02, "准备管线…") }

        // ---- 1) 上下文（换模型文件才重建）----
        if ctx != nil, loadedPath != modelPath { unload() }
        if ctx == nil {
            RMTrace.shared.log("SD 加载模型开始 path=…\(modelPath.suffix(44))", tag: "image")
            let t0 = Date()
            var cp = sd_ctx_params_t()
            sd_ctx_params_init(&cp)
            // ⚠️ strdup 出来的 C 字符串必须活过 new_sd_ctx()，withCString 的作用域指针会悬垂
            let cPath = strdup(modelPath)!
            defer { free(cPath) }
            cp.model_path = cPath
            cp.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount)))
            cp.vae_tiling_params.enabled = true   // VAE 分块解码：512² 峰值内存小一大截
            guard let c = new_sd_ctx(&cp) else {
                RMTrace.shared.log("SD new_sd_ctx 失败（内存不够 / 文件坏）", tag: "image")
                DispatchQueue.main.async {
                    onDone(nil, "模型加载失败：内存不够或文件损坏；去「库」删掉重下，或先关掉别的模型")
                }
                return
            }
            ctx = c
            loadedPath = modelPath
            RMTrace.shared.log("SD 模型加载完成 用时=\(Int(Date().timeIntervalSince(t0)))s", tag: "image")
        }
        guard let sdCtx = ctx else {
            DispatchQueue.main.async { onDone(nil, "引擎状态异常，重进生图页再试") }
            return
        }

        // ---- 2) 生成参数（init 给默认值，只覆盖我们关心的字段）----
        var gp = sd_img_gen_params_t()
        sd_img_gen_params_init(&gp)
        let cPrompt = strdup(prompt.isEmpty ? "a beautiful painting, soft light" : prompt)!
        let cNeg = strdup(negative)!
        defer { free(cPrompt); free(cNeg) }
        gp.prompt = cPrompt
        gp.negative_prompt = cNeg
        gp.width = Int32(size)
        gp.height = Int32(size)
        gp.batch_count = 1
        gp.seed = seed == 0 ? -1 : Int64(bitPattern: seed)   // -1 = 让库自己随机
        gp.sample_params.sample_steps = Int32(steps)
        gp.sample_params.sample_method = EULER_A_SAMPLE_METHOD
        gp.sample_params.guidance.txt_cfg = cfg

        // img2img：参考图编码成 RGBA 塞进 init_image
        var initMem: UnsafeMutableRawPointer?
        if let ref = reference {
            initMem = malloc(size * size * 4)
            if let mem = initMem, let im = Self.rgbaImage(from: ref, size: size, buffer: mem) {
                gp.init_image = im
                gp.strength = 0.65
                RMTrace.shared.log("SD img2img 模式 strength=0.65", tag: "image")
            }
        }
        defer { if let m = initMem { free(m) } }

        // ---- 3) 进度挂钩 + 生成 ----
        Self.activeStep = { step, total in
            let frac = Double(step) / Double(total)
            onProgress(0.05 + 0.9 * frac, "扩散去噪 \(step)/\(total) 步…")
        }
        defer { Self.activeStep = nil }

        var images: UnsafeMutablePointer<sd_image_t>? = nil
        var count: Int32 = 0
        let t1 = Date()
        let ok = generate_image(sdCtx, &gp, &images, &count)
        let dt = Date().timeIntervalSince(t1)
        RMTrace.shared.log("SD generate_image ok=\(ok) n=\(count) 用时=\(Int(dt))s", tag: "image")

        // ---- 4) 取结果（⚠️ sd.cpp 约定：结果内存由调用方 free）----
        var out: UIImage? = nil
        if ok, let images, count > 0 {
            let first = images[0]
            if let data = first.data, first.width > 0, first.height > 0 {
                out = Self.imageFromRGBA(data: data, w: Int(first.width), h: Int(first.height))
            }
            for i in 0..<Int(count) { free(images[i].data) }
            free(images)
        } else if let images, count > 0 {
            for i in 0..<Int(count) { free(images[i].data) }
            free(images)
        }

        DispatchQueue.main.async {
            if let out {
                onDone(out, "")
            } else {
                onDone(nil, "这次没生成出来：可能被停止，或内存吃紧；试试 384 尺寸或重新生成")
            }
        }
    }

    // MARK: - 像素工具

    /// 把参考图画成 size×size 的 RGBA（sd_image_t 语义：channel=4、RGBA8）
    private static func rgbaImage(from img: UIImage, size: Int, buffer: UnsafeMutableRawPointer) -> sd_image_t? {
        var src = img.cgImage
        if src == nil, let re = UIImage(data: img.pngData() ?? Data()) { src = re.cgImage }
        guard let cg = src,
              let ctx = CGContext(data: buffer, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return sd_image_t(width: UInt32(size), height: UInt32(size), channel: 4,
                          data: buffer.assumingMemoryBound(to: UInt8.self))
    }

    /// RGBA8 → UIImage（自己 malloc 拷一份，别把库的指针交给 CG，free 时机不受控）
    private static func imageFromRGBA(data: UnsafeMutablePointer<UInt8>, w: Int, h: Int) -> UIImage? {
        let bytes = w * h * 4
        guard let mem = malloc(bytes) else { return nil }
        memcpy(mem, data, bytes)
        defer { free(mem) }
        guard let ctx = CGContext(data: mem, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }
}
