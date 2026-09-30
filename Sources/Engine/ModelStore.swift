import Foundation

enum RMModelKind: String {
    case llm
    case image
}

/// 模型擅长的角色。任务路由只加载命中的那一个，其他模型保持未加载（不占内存）。
enum RMRole: String {
    case general = "通用"
    case code    = "代码"
    case math    = "数学"
}

enum RMModelState: String {
    case notDownloaded = "未下载"
    case downloading   = "下载中"
    case ready         = "已就绪"
}

struct RMModel: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: RMModelKind
    let quant: String
    let sizeGB: Double
    var state: RMModelState
    /// MoE（混合专家）：每次推理只激活其中一小部分专家，天然"跑需要的那部分"
    var isMoE: Bool = false
    var role: RMRole = .general

    var label: String { "\(name) · \(quant)" }
    var sizeLabel: String { String(format: "%.1f GB", sizeGB) }
}

/// 模型库：Chat（LLM）与生图各自维护当前模型，两边都能切换。
final class ModelStore: ObservableObject {
    @Published var models: [RMModel] = [
        // ---- 对话（GGUF / llama.cpp）----
        RMModel(id: "qwen25-15b", name: "Qwen2.5-1.5B-Instruct", kind: .llm, quant: "Q5_K_M", sizeGB: 1.1, state: .ready),
        RMModel(id: "llama32-1b", name: "Llama-3.2-1B-Instruct", kind: .llm, quant: "Q4_K_M", sizeGB: 0.8, state: .ready),
        RMModel(id: "gemma2-2b",  name: "Gemma-2-2B-Instruct",   kind: .llm, quant: "Q4_K_M", sizeGB: 1.6, state: .notDownloaded),
        // MoE：总参数大但每次只激活一小部分，是"按需跑部分"最省内存的一类
        RMModel(id: "qwen3-30b-a3b", name: "Qwen3-30B-A3B (MoE)", kind: .llm, quant: "Q4_K_M", sizeGB: 16.0, state: .notDownloaded, isMoE: true),
        // ---- 生图（Core ML）----
        RMModel(id: "sd15-q6", name: "Stable Diffusion 1.5", kind: .image, quant: "Q6", sizeGB: 1.3, state: .ready),
        RMModel(id: "sdxl-q6", name: "SDXL (轻量)",          kind: .image, quant: "Q6", sizeGB: 2.4, state: .notDownloaded)
    ]

    @Published var currentLLMId: String   = "qwen25-15b"
    @Published var currentImageId: String = "sd15-q6"

    var llmModels:   [RMModel] { models.filter { $0.kind == .llm } }
    var imageModels: [RMModel] { models.filter { $0.kind == .image } }

    var currentLLM:   RMModel? { models.first { $0.id == currentLLMId } }
    var currentImage: RMModel? { models.first { $0.id == currentImageId } }

    @discardableResult
    func select(_ m: RMModel) -> Bool {
        guard m.state == .ready else { return false }
        switch m.kind {
        case .llm:   currentLLMId = m.id
        case .image: currentImageId = m.id
        }
        return true
    }

    /// 本地 GGUF 路径（Documents/Models/<id>.gguf）
    func localPath(for m: RMModel) -> String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        return (docs as NSString).appendingPathComponent("Models/\(m.id).gguf")
    }

    /// 任务路由：按问题关键词挑最合适的已就绪模型。
    /// 关键点——返回谁，就只加载谁；没被选中的模型保持未加载，一点内存都不占。
    func route(for question: String) -> RMModel? {
        let q = question.lowercased()
        let codeKW = ["代码", "code", "函数", "function", "bug", "swift", "python", "javascript", "报错", "异常", "编译"]
        let mathKW = ["计算", "数学", "math", "证明", "求解", "方程", "等于", "几加", "乘以"]
        if codeKW.contains(where: { q.contains($0) }), let m = ready(role: .code)    { return m }
        if mathKW.contains(where: { q.contains($0) }), let m = ready(role: .math)    { return m }
        return currentLLM
    }

    private func ready(role: RMRole) -> RMModel? {
        models.first { $0.kind == .llm && $0.role == role && $0.state == .ready }
    }
}
