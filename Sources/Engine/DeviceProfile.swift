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

        /// 实际送进模型的上下文长度（不是存档容量）
        var ctxTokens: Int {
            switch self {
            case .tiny:   return 4096
            case .small:  return 8192
            case .mid:    return 16384
            case .large:  return 32768
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
    }

    /// 推荐预算：给系统留 ~1.2GB 余量，且不超过总内存 65%
    static func recommended(for total: Double) -> Double {
        min(total * 0.65, max(total - 1.2, 0.5))
    }

    var recommendedGB: Double { Self.recommended(for: totalGB) }

    /// 引擎上报的当前实际占用（GB）
    @Published var usedGB: Double = 0

    /// Metal（GPU）总开关。手动关掉后置 0 层，推理走纯 CPU——内存和发热都降，但会慢。
    @Published var metalEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "rymind.metalEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "rymind.metalEnabled") }
    }

    /// 实际送进 llama 的 GPU 层数（关 Metal 就是 0）
    var effectiveGpuLayers: Int { metalEnabled ? tier.gpuLayers : 0 }

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
