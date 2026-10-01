import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var text: String
    var isUser: Bool
    var ts: Date

    init(id: UUID = UUID(), text: String, isUser: Bool, ts: Date = Date()) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.ts = ts
    }
}

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    var snippet: String {
        for m in messages.reversed() where !m.text.isEmpty { return m.text }
        return "没有消息"
    }
}

/// 对话记录：多会话 + 本地持久化（Documents/sessions.json）
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published var sessions: [ChatSession] = []
    @Published var currentId: UUID = UUID()

    private let fileName = "sessions.json"
    private let fm = FileManager.default

    private init() {
        load()
        if sessions.isEmpty { makeCurrentSession(title: "新对话") }
        else if !sessions.contains(where: { $0.id == currentId }) { currentId = sessions[0].id }
    }

    private var storeURL: URL {
        docsURL().appendingPathComponent(fileName)
    }

    var current: ChatSession? { sessions.first { $0.id == currentId } }
    var messages: [ChatMessage] { current?.messages ?? [] }

    func docsURL() -> URL {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        return URL(fileURLWithPath: docs)
    }

    // MARK: - 会话管理

    @discardableResult
    func makeCurrentSession(title: String) -> ChatSession {
        let s = ChatSession(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), messages: [])
        sessions.insert(s, at: 0)
        currentId = s.id
        save()
        return s
    }

    func select(_ id: UUID) {
        currentId = id
        save()
    }

    /// 真删。删的是当前会话就把当前指到剩下第一个；全删光了自动建新的。
    /// ⚠️ 顺序很关键：remove 之后先判空再取 sessions[0]，否则删最后一个会下标越界崩溃。
    func delete(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = (currentId == id)
        sessions.remove(at: idx)
        if sessions.isEmpty {
            // 一个不剩 → 自动新建一个空的，界面不至于空掉
            makeCurrentSession(title: "新对话")
            return
        }
        if wasCurrent {
            // 删掉的是当前会话：接着往下走（原来的下一个，没了就取最后一个）
            let nextIdx = min(idx, sessions.count - 1)
            currentId = sessions[nextIdx].id
        } else if !sessions.contains(where: { $0.id == currentId }) {
            currentId = sessions[0].id
        }
        save()
    }

    /// 新建对话并切过去（会话列表两处按钮都调这个）
    @discardableResult
    func newSession(title: String = "新对话") -> ChatSession {
        return makeCurrentSession(title: title)
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = title
        save()
    }

    func clearCurrent() {
        guard let i = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        sessions[i].messages = []
        sessions[i].updatedAt = Date()
        save()
    }

    var currentTitle: String { current?.title ?? "新对话" }

    // MARK: - 消息

    func append(text: String, isUser: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        sessions[i].messages.append(ChatMessage(text: text, isUser: isUser))
        sessions[i].updatedAt = Date()
        // 用第一条用户消息当标题，方便在列表里认
        if sessions[i].messages.count == 1, isUser, text.count > 2 {
            let t = text.hasPrefix("/") ? String(text.dropFirst()) : text
            sessions[i].title = String(t.prefix(18))
        }
        save()
    }

    func append(_ msg: ChatMessage) {
        guard let i = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        sessions[i].messages.append(msg)
        sessions[i].updatedAt = Date()
        save()
    }

    func replace(id: UUID, with text: String) {
        guard let i = sessions.firstIndex(where: { $0.id == currentId }) else { return }
        for j in sessions[i].messages.indices where sessions[i].messages[j].id == id {
            sessions[i].messages[j].text = text
        }
        save()
    }

    // MARK: - 持久化

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: storeURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([ChatSession].self, from: data) else { return }
        sessions = list
    }
}
