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
