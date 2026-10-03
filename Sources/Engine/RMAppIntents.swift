import Foundation
import UIKit
import AppIntents

/// 让 RyMind 的 3 个动作直接出现在 iOS「快捷指令」App 里（URL scheme 不会自动列出，必须靠 App Intents）。
/// 设备是 iPadOS 27，框架可用；这里用 @available(iOS 16, *) 兜底，避免工程部署目标较低时编译报错。
@available(iOS 16, *)
struct GetModelsIntent: AppIntent {
    static let title: LocalizedStringResource = "获取 RyMind 模型列表"
    static let description = IntentDescription("把 RyMind 里可用的聊天模型列表复制到剪贴板，方便配合「从列表中选取」")
    static var openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary { Summary("获取 RyMind 模型列表") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ModelStore.shared
        var lines: [String] = []
        for (i, m) in store.llmModels.enumerated() {
            let st = m.state == .ready ? "已下载" : (m.state == .downloading ? "下载中" : "未下载")
            let cur = store.currentLLMId == m.id ? " [当前]" : ""
            lines.append("\(i + 1). \(m.id) | \(m.name) | \(st)\(cur)")
        }
        if !store.imageModels.isEmpty {
            for m in store.imageModels {
                lines.append("- 生图 | \(m.name) | \(m.state == .ready ? "已下载" : "未下载")")
            }
        }
        if lines.isEmpty { lines.append("（一个模型都没有，去「库 → 模型」先下一个）") }
        let full = lines.joined(separator: "\n")
        UIPasteboard.general.string = full
        RMShortcuts.shared.lastResult = full
        RMTrace.shared.log("快捷指令(模型列表) \(lines.count) 条", tag: "chat")
        return .result(dialog: "模型列表已复制到剪贴板（\(lines.count) 条）")
    }
}

@available(iOS 16, *)
struct NewChatIntent: AppIntent {
    static let title: LocalizedStringResource = "RyMind 新建会话"
    static let description = IntentDescription("在 RyMind 里创建一个新会话")
    static var openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary { Summary("在 RyMind 新建会话") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = SessionStore.shared.newSession()
        RMTrace.shared.log("快捷指令(新建会话) \(s.title)", tag: "chat")
        return .result(dialog: "已创建新会话：\(s.title)")
    }
}

@available(iOS 16, *)
struct ChatWithModelIntent: AppIntent {
    static let title: LocalizedStringResource = "用 RyMind 模型发消息"
    static let description = IntentDescription("把内容发给指定 RyMind 模型，并把回答复制到剪贴板")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "模型名称或序号", description: "用「获取模型列表」里的名称或序号")
    var model: String

    @Parameter(title: "消息内容")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("用 \(\.$model) 发送 \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !text.isEmpty else {
            return .result(dialog: "消息内容不能为空")
        }
        // 解析模型（轻量，主线程即可）
        let models = ModelStore.shared.llmModels
        var hit: RMModel? = nil
        if let idx = Int(model.trimmingCharacters(in: .whitespaces)), idx >= 1, idx <= models.count {
            hit = models[idx - 1]
        }
        if hit == nil {
            let k = model.trimmingCharacters(in: .whitespaces).lowercased()
            hit = models.first { $0.id.lowercased() == k || $0.name.lowercased() == k }
        }
        guard let m = hit else {
            return .result(dialog: "没找到模型「\(model)」，先跑「获取模型列表」拿列表")
        }
        guard m.state == .ready else {
            return .result(dialog: "「\(m.name)」还没下载完，先去「库 → 模型」下好")
        }
        // 重活在后台跑（openAppWhenRun 已在 App 进程内，可占内存，但别卡主线程）
        let answer = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dev = DeviceProfile()
                let ctx = dev.resolveContext(weightGB: m.sizeGB, requested: dev.ctxCapTokens)
                let gpu = dev.metalEnabled ? dev.tier.gpuLayers : 0
                let sys = "你是 RyMind 的本地助手，跑在 iPad 上、全程离线。用简体中文、Natural、口语化地回答；一次三五句话，别输出代码，别编造。"
                let loaded = LlamaEngine.shared.load(modelId: m.id,
                                                      path: ModelStore.shared.localPath(for: m),
                                                      ctxTokens: ctx, gpuLayers: gpu, sizeGB: m.sizeGB)
                guard loaded else { cont.resume(returning: ""); return }
                let out = LlamaEngine.shared.generate(brandHint: m.id, system: sys, prompt: text,
                                                      history: [], maxTokensOverride: 768) { _ in }
                cont.resume(returning: out)
            }
        }
        if answer.isEmpty {
            return .result(dialog: "（\(m.name) 这次没吐出东西；换个问法或换个模型）")
        }
        UIPasteboard.general.string = answer
        RMShortcuts.shared.lastResult = answer
        RMTrace.shared.log("快捷指令(发消息) \(m.id) 字数=\(answer.count)", tag: "chat")
        return .result(dialog: "回答已复制到剪贴板（\(answer.count) 字）")
    }
}

@available(iOS 16, *)
struct RyMindAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: AppShortcut {
        AppShortcut(intent: GetModelsIntent(),
                    phrases: ["获取 RyMind 模型列表", "RyMind 模型列表"],
                    shortTitle: "模型列表",
                    systemImageName: "list.bullet")
    }
}

@available(iOS 16, *)
struct RyMindNewChatShortcuts: AppShortcutsProvider {
    static var appShortcuts: AppShortcut {
        AppShortcut(intent: NewChatIntent(),
                    phrases: ["用 RyMind 新建会话", "RyMind 新会话"],
                    shortTitle: "新建会话",
                    systemImageName: "plus.bubble")
    }
}

@available(iOS 16, *)
struct RyMindChatShortcuts: AppShortcutsProvider {
    static var appShortcuts: AppShortcut {
        AppShortcut(intent: ChatWithModelIntent(),
                    phrases: ["用 RyMind 发消息", "RyMind 发消息"],
                    shortTitle: "发消息",
                    systemImageName: "bubble.left.and.bubble.right")
    }
}
