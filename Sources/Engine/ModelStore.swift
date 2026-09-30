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
    let brand: String
    let kind: RMModelKind
    let quant: String
    let sizeGB: Double
    var state: RMModelState
    /// MoE（混合专家）：每次推理只激活其中一小部分专家，天然"跑需要的那部分"
    var isMoE: Bool = false
    var role: RMRole = .general
    /// 主源（魔搭，国内快）
    let primaryURL: String?
    /// 镜像源（hf-mirror），主源失败自动切这里
    let mirrorURL: String

    var label: String { "\(name) · \(quant)" }
    var sizeLabel: String { String(format: "%.1f GB", sizeGB) }
    var hasSource: Bool { !(primaryURL?.isEmpty == true && mirrorURL.isEmpty) }
}

/// 模型库：Chat（LLM）与生图各自维护当前模型，两边都能切换。
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var models: [RMModel] = [
        // ---- Qwen（阿里）· 魔搭主源，已验证 200 ----
        RMModel(id: "qwen25-05b", name: "Qwen2.5-0.5B-Instruct", brand: "Qwen", kind: .llm,
                quant: "Q5_K_M", sizeGB: 0.4, state: .notDownloaded,
                primaryURL: "https://www.modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/qwen2.5-0.5b-instruct-q5_k_m.gguf",
                mirrorURL:   "https://hf-mirror.com/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q5_k_m.gguf"),

        RMModel(id: "qwen25-15b", name: "Qwen2.5-1.5B-Instruct", brand: "Qwen", kind: .llm,
                quant: "Q5_K_M", sizeGB: 1.1, state: .notDownloaded,
                primaryURL: "https://www.modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q5_k_m.gguf",
                mirrorURL:   "https://hf-mirror.com/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q5_k_m.gguf"),

        // ---- Llama（Meta）· hf-mirror，已验证 ----
        RMModel(id: "llama32-1b", name: "Llama-3.2-1B-Instruct", brand: "Llama", kind: .llm,
                quant: "Q4_K_M", sizeGB: 0.8, state: .notDownloaded, primaryURL: nil,
                mirrorURL: "https://hf-mirror.com/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),

        // ---- Gemma（Google）· hf-mirror，已验证 ----
        RMModel(id: "gemma2-2b", name: "Gemma-2-2B-IT", brand: "Gemma", kind: .llm,
                quant: "Q4_K_M", sizeGB: 1.6, state: .notDownloaded, primaryURL: nil,
                mirrorURL: "https://hf-mirror.com/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"),

        // ---- MoE（按需激活专家，最省内存的一类；暂未内置下载源，可手动加 URL）----
        RMModel(id: "qwen3-moe", name: "Qwen3-30B-A3B (MoE)", brand: "Qwen", kind: .llm,
                quant: "Q4_K_M", sizeGB: 16.0, state: .notDownloaded, isMoE: true,
                primaryURL: nil, mirrorURL: ""),

        // ---- 生图（Core ML）----
        RMModel(id: "sd15-q6", name: "Stable Diffusion 1.5", brand: "SD", kind: .image,
                quant: "Q6", sizeGB: 1.3, state: .ready, primaryURL: nil, mirrorURL: ""),
        RMModel(id: "sdxl-q6", name: "SDXL (轻量)", brand: "SD", kind: .image,
                quant: "Q6", sizeGB: 2.4, state: .notDownloaded, primaryURL: nil, mirrorURL: "")
    ]

    @Published var currentLLMId: String   = "qwen25-15b"
    @Published var currentImageId: String = "sd15-q6"

    private init() { refreshStates() }

    var llmModels:   [RMModel] { models.filter { $0.kind == .llm } }
    var imageModels: [RMModel] { models.filter { $0.kind == .image } }

    var currentLLM:   RMModel? { models.first { $0.id == currentLLMId } }
    var currentImage: RMModel? { models.first { $0.id == currentImageId } }

    func model(id: String) -> RMModel? { models.first { $0.id == id } }

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

    /// 按本地文件是否存在刷新状态（LLM 看 gguf 是否落地）
    func refreshStates() {
        for i in models.indices {
            guard models[i].kind == .llm else { continue }
            let exists = FileManager.default.fileExists(atPath: localPath(for: models[i]))
            if exists {
                models[i].state = .ready
            } else if models[i].state == .ready {
                models[i].state = .notDownloaded
            }
        }
    }

    /// 删除本地模型文件（释放空间；模型本身仍在列表里可重新下载）
    func deleteLocal(_ m: RMModel) {
        try? FileManager.default.removeItem(atPath: localPath(for: m))
        refreshStates()
    }

    /// 手动添加一个自定义模型（粘贴 GGUF 直链）
    func addCustom(name: String, url: String, sizeGB: Double = 1.0) {
        let id = "custom-\(UUID().uuidString.prefix(8))"
        models.append(RMModel(id: id, name: name, brand: "自定义", kind: .llm,
                              quant: "GGUF", sizeGB: sizeGB, state: .notDownloaded,
                              primaryURL: nil, mirrorURL: url))
    }

    /// 任务路由：按问题关键词挑最合适的已就绪模型。
    /// 返回谁，就只加载谁；没被选中的模型保持未加载，一点内存都不占。
    func route(for question: String) -> RMModel? {
        let q = question.lowercased()
        let codeKW = ["代码", "code", "函数", "function", "bug", "swift", "python", "javascript", "报错", "异常", "编译"]
        let mathKW = ["计算", "数学", "math", "证明", "求解", "方程", "等于", "几加", "乘以"]
        if codeKW.contains(where: { q.contains($0) }), let m = ready(role: .code) { return m }
        if mathKW.contains(where: { q.contains($0) }), let m = ready(role: .math) { return m }
        return currentLLM
    }

    private func ready(role: RMRole) -> RMModel? {
        models.first { $0.kind == .llm && $0.role == role && $0.state == .ready }
    }
}
