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

    // MARK: - 内存预算 → 生图安全参数（这才是「性能页内存预算」真正生效的地方）

    /// ⚠️ 关键纪律：iOS 的「内存超限」是 jetsam，发的是 **SIGKILL**，任何 signal handler 都拦不住
    /// （RMGuard 救不了这种崩）。所以唯一正路是**从源头把峰值内存压在预算内**，而不是崩了再兜底。
    /// 这个预算来自「性能」页的内存分配滑块（`DeviceProfile.budgetGB`），它会**真限制**生图工作负载。
    struct SDPlan {
        let maxSize: Int
        let maxSteps: Int
        let note: String
    }

    /// 按内存预算推导生图的安全参数（预算越小 → 尺寸/步数越保守）。
    /// 分辨率²决定 UNet 激活内存（峰值的最大来源），所以预算紧时先砍尺寸；步数影响单图耗时、不影响峰值。
    static func sdPlan(budgetGB: Double) -> SDPlan {
        if budgetGB >= 3.2 { return SDPlan(maxSize: 512, maxSteps: 20, note: "") }
        if budgetGB >= 2.4 { return SDPlan(maxSize: 512, maxSteps: 14, note: "（内存偏紧，步数已自动降到 14）") }
        if budgetGB >= 1.8 { return SDPlan(maxSize: 384, maxSteps: 12, note: "（内存紧，已降到 384 尺寸 / 12 步）") }
        if budgetGB >= 1.3 { return SDPlan(maxSize: 384, maxSteps: 8,  note: "（内存很紧，已降到 384 尺寸 / 8 步）") }
        return SDPlan(maxSize: 320, maxSteps: 6, note: "（内存极紧，已降到 320 尺寸 / 6 步，画质会下降）")
    }

    /// 当前进程真实物理内存（GB）—— 生图前预检用，避免明知道快顶穿还硬跑
    private static var footprintGB: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_073_741_824.0 : 0
    }

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
    /// 上一次回报过的步数（去重用，避免每步都往主线程推）
    private static var lastReportedStep = -1

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

        // ---- 0) 内存预算硬限制（「性能」页滑块在这里真正生效）----
        let budget = DeviceProfile.shared.budgetGB
        let plan = Self.sdPlan(budgetGB: budget)
        // ⚠️ 预检：当前已经吃到预算 85% 以上，硬跑大概率被 jetsam 杀 → 直接拒，给人话
        if budget > 0, Self.footprintGB > budget * 0.85 {
            RMTrace.shared.log("SD 预检不过：footprint=\(String(format: "%.2f", Self.footprintGB))GB 已超预算 \(String(format: "%.2f", budget))GB 的 85%",
                               tag: "image")
            DispatchQueue.main.async {
                onDone(nil, "内存已经很吃紧（约 \(String(format: "%.1f", Self.footprintGB))GB / 预算 \(String(format: "%.1f", budget))GB），先回主屏清一下后台应用再生成")
            }
            return
        }
        let safeSize  = min(size, plan.maxSize)
        let safeSteps = min(steps, plan.maxSteps)
        if safeSize != size || safeSteps != steps {
            RMTrace.shared.log("SD 按内存预算夹参数 size \(size)→\(safeSize) steps \(steps)→\(safeSteps)（预算 \(String(format: "%.1f", budget))GB）",
                               tag: "image")
        }

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
            cp.model_path = UnsafePointer(cPath)
            // 4GB 设备上加载阶段也可能直接顶穿内存，同样兜住
            cp.n_threads = Int32(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount)))
            var newCtx: OpaquePointer? = nil
            let loaded = RMGuard.run { newCtx = new_sd_ctx(&cp) }
            guard let c = loaded ? newCtx : nil else {
                RMTrace.shared.log("SD new_sd_ctx 失败 loaded=\(loaded)（内存不够 / 文件坏）", tag: "image")
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
        gp.prompt = UnsafePointer(cPrompt)
        gp.negative_prompt = UnsafePointer(cNeg)
        gp.width = Int32(safeSize)
        gp.height = Int32(safeSize)
        gp.batch_count = 1
        gp.seed = seed == 0 ? -1 : Int64(bitPattern: seed)   // -1 = 让库自己随机
        gp.sample_params.sample_steps = Int32(safeSteps)
        gp.sample_params.sample_method = EULER_A_SAMPLE_METHOD
        gp.sample_params.guidance.txt_cfg = cfg
        gp.vae_tiling_params.enabled = true   // VAE 分块解码：512² 峰值内存小一大截

        // img2img：参考图编码成 RGBA 塞进 init_image
        var initMem: UnsafeMutableRawPointer?
        if let ref = reference {
            initMem = malloc(safeSize * safeSize * 4)
            if let mem = initMem, let im = Self.rgbaImage(from: ref, size: safeSize, buffer: mem) {
                gp.init_image = im
                gp.strength = 0.65
                RMTrace.shared.log("SD img2img 模式 strength=0.65", tag: "image")
            }
        }
        defer { if let m = initMem { free(m) } }

        // ---- 3) 进度挂钩 + 生成 ----
        // ⚠️ 进度回调在 C 的推理线程上跑，onProgress 会写 SwiftUI @State —— 必须回主线程，
        // 而且每步都 dispatch 会把主线程刷爆（进度条一闪一闪就是这么来的），这里只在步数变了才报。
        Self.lastReportedStep = -1
        Self.activeStep = { step, total in
            guard total > 0, step != Self.lastReportedStep else { return }
            Self.lastReportedStep = step
            let frac = Double(max(0, step)) / Double(total)
            let text = "扩散去噪 \(step)/\(total) 步…"
            DispatchQueue.main.async { onProgress(0.05 + 0.9 * frac, text) }
        }
        defer { Self.activeStep = nil }

        var images: UnsafeMutablePointer<sd_image_t>? = nil
        var count: Int32 = 0
        let t1 = Date()
        // ⚠️ 4GB 的 iPad 上 512² 去噪 peaked 内存很容易顶穿，直接 SIGSEGV 把 App 带走。
        // 用 RMGuard 把信号接住，至少给一句人话 + trace 留证。
        var ranOK = false
        let survived = RMGuard.run {
            ranOK = generate_image(sdCtx, &gp, &images, &count)
        }
        let ok = survived && ranOK
        let dt = Date().timeIntervalSince(t1)
        if !survived {
            RMTrace.shared.log("SD generate_image 崩溃被兜底接住（内存/越界）信号=\(rm_guard_signal())，用时=\(Int(dt))s", tag: "crash")
        }
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

        if let out {
            DispatchQueue.main.async { onDone(out, "") }
            return
        }
        // 没出图：C 那边多半已经踩坏了自己，ctx 留着只会下次更糟 —— 扔掉重建
        let msg: String
        if survived {
            msg = "这次没生成出来：可能被停止了，或者内存吃紧（多试两次；去「性能」页把内存预算调小、会自动降到更小尺寸更稳）"
        } else {
            unload()
            msg = "生成时崩了（多半是内存不够）：去「性能」页把内存预算调小，会自动降到 384/320 尺寸更稳；或先回主屏清掉后台应用"
        }
        RMTrace.shared.log("SD 出图失败 survived=\(survived) ranOK=\(ranOK)", tag: "image")
        DispatchQueue.main.async { onDone(nil, msg) }
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
