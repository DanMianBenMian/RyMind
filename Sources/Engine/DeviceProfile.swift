import Foundation

/// 设备内存画像与推理档位。iOS 设备内存 4~24GB 不等，所有推理参数按预算自适应。
final class DeviceProfile: ObservableObject {

    enum Tier: String {
        case tiny, small, mid, large, xlarge

        /// 权重量化级别：内存越小越激进，但尽量不掉质量
        var quant: String {
            switch self {
            case .tiny:   return "Q4_K_M"
            case .small:  return "Q4_K_M"
            case .mid:    return "Q5_K_M"
            case .large:  return "Q6_K"
            case .xlarge: return "Q8_0"
            }
        }

        /// 上下文长度的**默认值**（不是天花板）。
        /// ⚠️ 它不再和 GPU 层数 / 线程 / 批次那样跟着性能档位走 ——
        /// 性能调节（能上几层 Metal、开几个线程、划多少内存）只影响跑得快不快，
        /// 上下文长度由「你设的上限」和「这台设备装得下」两个条件决定，见 resolveContext()。
        var defaultCtxTokens: Int {
            switch self {
            case .tiny:   return 4096
            case .small:  return 8192
            case .mid:    return 16384
            case .large:  return 32768
            case .xlarge: return 65536
            }
        }

        /// Max 模式的默认窗口（比普通大一档，用来"高强度思考"：装得下更长历史 + 更长的推理链）。
        var defaultMaxCtxTokens: Int {
            switch self {
            case .tiny:   return 8192
            case .small:  return 16384
            case .mid:    return 32768
            case .large:  return 49152
            case .xlarge: return 65536
            }
        }

        /// KV cache 量化（q8_0）省内存，仅超大档可关闭
        var kvQuant: Bool { self != .xlarge }

        /// 上 Metal 的层数
        var gpuLayers: Int {
            switch self {
            case .tiny:   return 12
            case .small:  return 20
            case .mid:    return 28
            case .large:  return 35
            case .xlarge: return 99
            }
        }

        /// 小内存设备：必须先筛关键词再推理（只喂相关片段）
        var requiresKeywordFilter: Bool { self == .tiny || self == .small }
    }

    let totalGB: Double
    @Published var budgetGB: Double

    init() {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let total = Double(bytes) / 1_073_741_824.0
        self.totalGB = max(total, 0.5)
        self.budgetGB = Self.recommended(for: self.totalGB)
        // 上下文默认值取档位默认；用户设过就用用户设的（0 = 没设过）
        let ud = UserDefaults.standard
        let c = ud.integer(forKey: "rymind.ctxCap")
        let x = ud.integer(forKey: "rymind.maxCtxCap")
        self.ctxCapTokens     = (c == 0) ? tier.defaultCtxTokens     : c
        self.maxCtxCapTokens  = (x == 0) ? tier.defaultMaxCtxTokens  : x
    }

    /// 推荐预算：给系统留 ~1.2GB 余量，且不超过总内存 65%
    static func recommended(for total: Double) -> Double {
        min(total * 0.65, max(total - 1.2, 0.5))
    }

    var recommendedGB: Double { Self.recommended(for: totalGB) }

    /// 引擎上报的当前实际占用（GB）
    @Published var usedGB: Double = 0

    /// Metal（GPU）总开关。手动关掉后置 0 层，推理走纯 CPU——内存和发热都降，但会慢。
    /// ⚠️ @Published 不能挂在 computed property 上，所以用存储属性 + didSet 落盘。
    @Published var metalEnabled: Bool = true {
        didSet { UserDefaults.standard.set(metalEnabled, forKey: "rymind.metalEnabled") }
    }

    /// 实际送进 llama 的 GPU 层数（关 Metal 就是 0）
    var effectiveGpuLayers: Int { metalEnabled ? tier.gpuLayers : 0 }

    // MARK: - 上下文长度（与性能档位解耦）

    /// 普通模式想用的上下文上限（用户在「高级」页调，持久化）
    @Published var ctxCapTokens: Int = 8192 {
        didSet { UserDefaults.standard.set(ctxCapTokens, forKey: "rymind.ctxCap") }
    }

    /// Max 模式想用的上下文上限（同上）
    @Published var maxCtxCapTokens: Int = 16384 {
        didSet { UserDefaults.standard.set(maxCtxCapTokens, forKey: "rymind.maxCtxCap") }
    }

    /// 这台设备**装得下**的上下文天花板（只按真实物理内存算）。
    /// ⚠️ 故意不读 budgetGB —— 内存预算是性能调节项，调它不该牵连上下文长度。
    /// 系统常驻 + UI 大约留 1.25GB；KV cache 每 1k token 约占权重的 0.16 倍（fp16 半精度）。
    func memoryContextCeiling(weightGB: Double) -> Int {
        let headroom = 1.25
        let kvTotal = max(0.30, totalGB - weightGB - headroom)
        let per1K   = max(0.030, weightGB * 0.16)
        return max(512, Int(kvTotal / per1K * 1000))
    }

    /// 最终送进模型的上下文 = min(用户想要的, 模型自身支持的上限, 这台设备装得下的)
    /// - weightGB: 这个模型的量化权重体积
    /// - requested: 用户/Max 想要的长度
    /// - modelMax:  模型文件自己支持的窗口（GGUF 训练窗口，超过就是paper-long没意义）
    func resolveContext(weightGB: Double, requested: Int, modelMax: Int = 32768) -> Int {
        let byMem = memoryContextCeiling(weightGB: weightGB)
        let cap = min(modelMax, byMem, 65536)
        let want = max(512, requested)
        return max(512, min(want, cap))
    }

    /// 进程实际物理内存占用（GB）
    var footprintGB: Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_073_741_824.0 : 0
    }

    /// 引擎上报优先；引擎未接时用进程真实占用兜底
    var effectiveUsedGB: Double { usedGB > 0 ? usedGB : footprintGB }

    /// 内存利用率 = 实际占用 / 已分配的内存预算（不是占总设备内存）
    /// 例：分配 2.4 GB、实际跑到 2.0 GB → 83.3%
    var usageRatio: Double {
        guard budgetGB > 0 else { return 0 }
        return min(effectiveUsedGB / budgetGB, 1.0)
    }

    /// 分配预算占设备总内存的比例
    var budgetRatio: Double {
        guard totalGB > 0 else { return 0 }
        return min(budgetGB / totalGB, 1.0)
    }

    var tier: Tier {
        switch budgetGB {
        case ..<1.5:  return .tiny
        case ..<2.5:  return .small
        case ..<4.5:  return .mid
        case ..<8.0:  return .large
        default:      return .xlarge
        }
    }

    var memoryUsageRatio: Double {
        guard totalGB > 0 else { return 0 }
        return budgetGB / totalGB
    }
}
