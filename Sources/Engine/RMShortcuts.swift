import Foundation
import UIKit

/// 快捷指令入口。App 注册了 `rymind://` 这个 scheme，三类动作：
///   · `rymind://models`                          → 模型列表（配合快捷指令的「从列表中选取」）
///   · `rymind://chat?model=<id或名>&text=<内容>`  → 给指定模型发一条消息，把回答写进剪贴板
///   · `rymind://newchat`                         → 新建会话（配合上一个「选取」用）
///
/// 结果统一写进剪贴板 + 在 App 顶上弹一条提示；快捷指令里接一个「从剪贴板获取」就能拿到。
final class RMShortcuts: ObservableObject {

    static let shared = RMShortcuts()

    enum Action: String {
        case models  = "models"
        case chat    = "chat"
        case newchat = "newchat"
    }

    /// 顶部浮层文案（几秒后自动收）
    @Published var banner: String = ""
    /// 最近一次的完整结果（「高级」页也能看到）
    @Published var lastResult: String = ""
    @Published var isBusy: Bool = false

    private var bannerWork: DispatchWorkItem?

    /// 冷启动时 delegate 收到的 URL 先存这儿，等 didBecomeActive 再执行
    static var pendingURL: URL?

    private init() {}

    // MARK: - 入口

    func handle(_ url: URL) {
        guard let host = url.host?.lowercased(), let act = Action(rawValue: host) else {
            show("不认识的指令：\(url.absoluteString)\n可用：models / chat / newchat")
            return
        }
        switch act {
        case .models:   runModels()
        case .chat:     runChat(url)
        case .newchat:  runNewChat()
        }
    }

    // MARK: - 1) 获取模型列表

    private func runModels() {
        let store = ModelStore.shared
        var lines: [String] = []
        for (i, m) in store.llmModels.enumerated() {
            let st = m.state == .ready ? "已下载" : (m.state == .downloading ? "下载中" : "未下载")
            let cur = store.currentLLMId == m.id ? " [当前]" : ""
            // 一行一条，快捷指令的「从列表中选取」直接拿去当选项
            lines.append("\(i + 1). \(m.id) | \(m.name) | \(st)\(cur)")
        }
        if !store.imageModels.isEmpty {
            for m in store.imageModels {
                lines.append("- 生图 | \(m.name) | \(m.state == .ready ? "已下载" : "未下载")")
            }
        }
        if lines.isEmpty { lines.append("（一个模型都没有，去「库 → 模型」先下一个）") }
        publish(lines.joined(separator: "\n"), short: "模型列表已复制到剪贴板（\(lines.count) 条）")
    }

    // MARK: - 2) 向（模型名称）发消息

    private func runChat(_ url: URL) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let items = comps?.queryItems ?? []
        let key   = items.first(where: { $0.name == "model" })?.value ?? ""
        let text  = items.first(where: { $0.name == "text" })?.value ?? ""

        guard !text.isEmpty else {
            let msg = "缺参数：rymind://chat?model=<模型id或名称>&text=<要发的内容>"
            publish(msg, short: "参数不全")
            return
        }
        // 「从列表中选取」拿到的是带空格/大小写差异的「名称」，也允许直接填列表里的序号
        let models = ModelStore.shared.llmModels
        var hit: RMModel? = nil
        if let idx = Int(key.trimmingCharacters(in: .whitespaces)), idx >= 1, idx <= models.count {
            hit = models[idx - 1]
        }
        if hit == nil {
            let k = key.trimmingCharacters(in: .whitespaces).lowercased()
            hit = models.first { $0.id.lowercased() == k || $0.name.lowercased() == k }
        }
        guard let m = hit else {
            let msg = "没找到模型「\(key)」——先跑一次 rymind://models 拿列表，选完把序号/名称填进 model 参数"
            publish(msg, short: "模型不存在")
            return
        }
        launch(m, text)
    }

    private func launch(_ m: RMModel, _ text: String) {
        guard m.state == .ready else {
            let msg = "「\(m.name)」还没下载完，先去「库 → 模型」下好"
            publish(msg, short: "模型没下好")
            return
        }
        DispatchQueue.main.async { self.isBusy = true }
        show("正在用 \(m.name) 回答…（别切走 App，等它出完）")

        let dev = DeviceProfile()
        let ctxTokens = dev.resolveContext(weightGB: m.sizeGB, requested: dev.ctxCapTokens)
        let gpu = dev.metalEnabled ? dev.tier.gpuLayers : 0
        RMTrace.shared.log("快捷指令 chat model=\(m.id) ctx=\(ctxTokens) gpu=\(gpu) chars=\(text.count)", tag: "chat")

        DispatchQueue.global(qos: .userInitiated).async {
            var out = ""
            var loadFail = false
            let survived = RMGuard.run {
                loadFail = !LlamaEngine.shared.load(modelId: m.id,
                                                    path: ModelStore.shared.localPath(for: m),
                                                    ctxTokens: ctxTokens,
                                                    gpuLayers: gpu,
                                                    sizeGB: m.sizeGB)
            }
            if !survived || loadFail {
                let msg = "「\(m.name)」加载失败：内存不够或文件损坏（加载崩溃被兜底接住）"
                RMTrace.shared.log(msg, tag: "crash")
                publish(msg, short: "加载失败")
                return
            }
            let sys = "你是 RyMind 的本地助手，跑在 iPad 上、全程离线。用简体中文、Natural、口语化地回答；一次三五句话，别输出代码，别编造。"
            let ranOK = RMGuard.run {
                out = LlamaEngine.shared.generate(brandHint: m.id, system: sys, prompt: text,
                                                  history: [], maxTokensOverride: 768) { _ in }
            }
            let body = ranOK ? out : ""
            RMTrace.shared.log("快捷指令 chat 完成 ranOK=\(ranOK) 字数=\(body.count)", tag: "chat")
            if body.isEmpty {
                publish("（\(m.name) 这次没吐出东西；换个问法或换个模型）", short: "没输出")
                return
            }
            publish(body, short: "回答已复制到剪贴板（\(body.count) 字）")
        }
    }

    // MARK: - 3) 创建新会话

    private func runNewChat() {
        let s = SessionStore.shared.newSession()
        let msg = "新会话已创建：\(s.title)（现在共 \(SessionStore.shared.sessions.count) 个会话）"
        RMTrace.shared.log(msg, tag: "chat")
        publish(msg, short: "已创建新会话")
    }

    // MARK: - 输出

    private func publish(_ full: String, short: String) {
        UIPasteboard.general.string = full
        lastResult = full
        show(short)
    }

    private func show(_ s: String) {
        bannerWork?.cancel()
        let item = DispatchWorkItem {
            DispatchQueue.main.async {
                self.banner = ""
                self.isBusy = false
            }
        }
        bannerWork = item
        DispatchQueue.main.async { self.banner = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
    }

    /// 「高级」页用：把最近结果塞进剪贴板
    func copyResult() {
        guard !lastResult.isEmpty else { return }
        UIPasteboard.general.string = lastResult
    }
}
