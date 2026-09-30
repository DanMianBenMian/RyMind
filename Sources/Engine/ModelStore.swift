import Foundation

enum RMModelKind: String {
    case llm
    case image
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

    var label: String { "\(name) · \(quant)" }
    var sizeLabel: String { String(format: "%.1f GB", sizeGB) }
}

/// 模型库：Chat（LLM）与生图各自维护一个当前模型，两边都能切换。
final class ModelStore: ObservableObject {
    @Published var models: [RMModel] = [
        // ---- 对话（GGUF / llama.cpp）----
        RMModel(id: "qwen25-15b",  name: "Qwen2.5-1.5B-Instruct", kind: .llm, quant: "Q5_K_M", sizeGB: 1.1, state: .ready),
        RMModel(id: "llama32-1b",  name: "Llama-3.2-1B-Instruct", kind: .llm, quant: "Q4_K_M", sizeGB: 0.8, state: .ready),
        RMModel(id: "gemma2-2b",   name: "Gemma-2-2B-Instruct",   kind: .llm, quant: "Q4_K_M", sizeGB: 1.6, state: .notDownloaded),
        // ---- 生图（Core ML）----
        RMModel(id: "sd15-q6",     name: "Stable Diffusion 1.5",  kind: .image, quant: "Q6",  sizeGB: 1.3, state: .ready),
        RMModel(id: "sdxl-q6",     name: "SDXL (轻量)",           kind: .image, quant: "Q6",  sizeGB: 2.4, state: .notDownloaded)
    ]

    @Published var currentLLMId: String   = "qwen25-15b"
    @Published var currentImageId: String = "sd15-q6"

    var llmModels:   [RMModel] { models.filter { $0.kind == .llm } }
    var imageModels: [RMModel] { models.filter { $0.kind == .image } }

    var currentLLM:   RMModel? { models.first { $0.id == currentLLMId } }
    var currentImage: RMModel? { models.first { $0.id == currentImageId } }

    /// 切到某个模型；未下载的模型不允许切（返回 false 由 UI 提示去下载）
    @discardableResult
    func select(_ m: RMModel) -> Bool {
        guard m.state == .ready else { return false }
        switch m.kind {
        case .llm:   currentLLMId = m.id
        case .image: currentImageId = m.id
        }
        return true
    }
}
