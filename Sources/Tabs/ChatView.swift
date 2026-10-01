import SwiftUI
import PhotosUI
import UIKit

/// 从文件库选中的文件（path 是 unix 路径）
struct PickedFile: Identifiable {
    let path: String
    let name: String
    var id: String { path + "/" + name }
}

/// 文件库浏览选择器（复用 FileStore 的目录树）
private struct FilePickerSheet: View {
    @EnvironmentObject private var fs: FileStore
    let onPick: (String, String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if fs.path != "/" {
                    Button { fs.up() } label: {
                        Label("上一级", systemImage: "folder")
                    }
                }
                ForEach(fs.entries) { e in
                    if e.isDir {
                        Button { fs.enter(e.name) } label: {
                            Label(e.name, systemImage: "folder")
                        }
                    } else {
                        Button { onPick(fs.path, e.name) } label: {
                            Label(e.name, systemImage: "doc")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(RMTheme.rail)
            .navigationTitle("从文件库选")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { fs.goRoot() } }
            }
        }
        .onAppear { fs.refresh() }
    }
}

/// 键盘弹起时把弹层收掉，避免点输入框冒出会话选择器打断键盘。
/// 用 addObserver 而不是 NotificationCenter.publisher（后者 iOS17+ 才有，当前 SDK 没有）。
final class RMKeyboardGuard: ObservableObject {
    @Published var keyboardUp = false
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.keyboardUp = true
            }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

struct ChatView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var device: DeviceProfile
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var engine: LlamaEngine
    @EnvironmentObject private var skillStore: SkillStore

    private let landscape: Bool

    @State private var input = ""
    @State private var maxMode = false
    @State private var statusLine = ""
    @State private var showSessions = false
    @State private var showAttach = false
    @State private var photoItem: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedSkillName: String?
    @State private var attachedFile: PickedFile?
    @State private var showFilePick = false

    @StateObject private var kb = RMKeyboardGuard()

    init(landscape: Bool) { self.landscape = landscape }

    private var messages: [ChatMessage] { sessions.messages }
    private var generating: Bool { engine.isGenerating }

    /// 上下文用量 = **当前打开这个会话**的占用（模型没加载/切会话都会跟着变）。
    /// 没加载模型时用本地估算（中文约 1 token/字、英文 4 字符 1 token）；生成中则优先用引擎真实值。
    private var sessionTokens: Int {
        var n = estTokens(sessions.currentTitle) + 8   // 模板本身的开销
        for m in sessions.messages { n += estTokens(m.text) }
        return n
    }
    private var usedTokens: Int {
        engine.isLoaded ? max(engine.ctxUsed, sessionTokens) : sessionTokens
    }
    private var usedK: Double { Double(max(usedTokens, 1)) / 1024.0 }
    /// Max 模式直接按 1000k 存档窗口显示；平时用模型真实窗口
    private var realK: Double { maxMode ? 1000.0 : Double(max(engine.ctxTotal, 1)) / 1024.0 }

    /// token 粗估（够用来显示"用了多少"）
    private func estTokens(_ s: String) -> Int {
        var cjk = 0
        for sc in s.unicodeScalars {
            let v = sc.value
            if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3000 && v <= 0x30FF) || (v >= 0x3400 && v <= 0x4DBF) { cjk += 1 }
        }
        let rest = max(0, s.count - cjk)
        return cjk + rest / 4 + 1
    }

    var body: some View {
        HStack(spacing: 0) {
            if landscape { sessionSidebar }
            mainColumn
        }
        .background(RMTheme.bg)
        .sheet(isPresented: Binding(get: { self.showSessions && !self.kb.keyboardUp },
                                    set: { v in self.showSessions = v; self.kb.keyboardUp = false })) {
            sessionSheet
        }
        .sheet(isPresented: $showAttach) { attachSheet }
        .sheet(isPresented: Binding(get: { self.showFilePick && !self.kb.keyboardUp },
                                    set: { v in self.showFilePick = v; self.kb.keyboardUp = false })) {
            FilePickerSheet { path, name in
                attachedFile = PickedFile(path: path, name: name)
                showFilePick = false
            }
        }
    }

    // MARK: - 主区

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { m in bubble(m) }
                    if messages.isEmpty {
                        Text("开始一个新话题吧。顶部有「新对话」，左下角是全部对话记录。")
                            .font(.system(size: 12))
                            .foregroundStyle(RMTheme.textSub)
                            .padding(.top, 40)
                    }
                }
                .padding(12)
            }
            composer
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if !landscape {
                    Button { showSessions = true } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13))
                            .foregroundStyle(RMTheme.accent)
                    }
                }
                Button { newChat() } label: {
                    Image(systemName: "square.compose")
                        .font(.system(size: 13))
                        .foregroundStyle(RMTheme.accent)
                }
                ModelPicker(kind: .llm)
                Spacer()
                Button { maxMode.toggle() } label: {
                    Text(maxMode ? "Max 开" : "Max 关")
                        .font(.system(size: 11))
                        .foregroundStyle(maxMode ? Color(hex: 0x0B1F1B) : RMTheme.textSub)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(maxMode ? RMTheme.accent : RMTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // 进度：当前会话已用 / 窗口（Max 就是 1000k）
            ProgressView(value: min(usedK, realK), total: max(realK, 0.001))
                .tint(RMTheme.accent)

            HStack(spacing: 6) {
                Text(String(format: "上下文已用 %.2fk / %.0fk", usedK, realK))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
                if maxMode {
                    Text("· 1000k 存档窗口，只喂本次相关片段（不占满 KV）")
                        .font(.system(size: 11))
                        .foregroundStyle(RMTheme.textSub)
                }
                Spacer()
            }

            Text(statusLine.isEmpty ? engine.note : statusLine)
                .font(.system(size: 11))
                .foregroundStyle(RMTheme.textSub)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.isUser { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 13))
                .foregroundStyle(m.isUser ? Color(hex: 0xE8F5F0) : Color(hex: 0xDCDCE0))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(m.isUser ? RMTheme.user : RMTheme.bot)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !m.isUser { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { showAttach.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RMTheme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
            }

            if attachedSkillName != nil || attachedImage != nil {
                Menu {
                    if let s = attachedSkillName { Button("移除 Skill：\(s)") { attachedSkillName = nil } }
                    if attachedImage != nil { Button("移除图片") { attachedImage = nil } }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 12))
                        .foregroundStyle(RMTheme.warn)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(RMTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            TextField("问点什么…", text: $input)
                .font(.system(size: 13))
                .foregroundStyle(RMTheme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RMTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .disabled(generating)

            // 生成中 → 终止键；否则发送键
            Button {
                if generating {
                    engine.stop()
                    statusLine = "正在终止…"
                } else {
                    send()
                }
            } label: {
                Image(systemName: generating ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(generating ? Color(hex: 0x1B1B1D) : Color(hex: 0x0B1F1B))
                    .frame(width: 30, height: 30)
                    .background(generating ? RMTheme.danger : RMTheme.accent)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RMTheme.rail)
    }

    // MARK: - 会话

    private func newChat() {
        input = ""
        statusLine = ""
        sessions.newSession(title: "新对话")
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("对话记录").font(.system(size: 13, weight: .medium)).foregroundStyle(RMTheme.text)
                Spacer()
                // 横屏这里必须能看见「新建」——带文字的按钮，别靠猜
                Button(action: newChat) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.compose").font(.system(size: 12))
                        Text("新建").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: 0x0B1F1B))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RMTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(sessions.sessions) { s in
                        sessionRow(s, compact: false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .background(RMTheme.rail)
        }
        .frame(width: 210)
    }

    private var sessionSheet: some View {
        NavigationStack {
            List {
                ForEach(sessions.sessions) { s in
                    sessionRow(s, compact: true)
                }
                .onDelete { idx in
                    // 倒序删（删完会自动补一个「新对话」，索引会变，别正序乱取）
                    for i in idx.sorted().reversed() where i < sessions.sessions.count {
                        sessions.delete(sessions.sessions[i].id)
                    }
                }
            }
            .listStyle(.plain)
            .background(RMTheme.rail)
            .navigationTitle("对话记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("新建对话") { newChat(); showSessions = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showSessions = false }
                }
            }
        }
    }

    private func sessionRow(_ s: ChatSession, compact: Bool) -> some View {
        let current = s.id == sessions.currentId
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(s.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(current ? RMTheme.accent : RMTheme.text)
                    .lineLimit(1)
                Spacer()
                Button {
                    sessions.delete(s.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(RMTheme.danger)
                }
                .buttonStyle(.plain)
            }
            Text(s.snippet)
                .font(.system(size: 11))
                .foregroundStyle(RMTheme.textSub)
                .lineLimit(compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(current ? RMTheme.surface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { switchTo(s.id); if compact { showSessions = false } }
    }

    /// 切会话：先掐掉正在生成的这一轮（否则旧回答会继续往新会话里写）、清掉输入框状态
    private func switchTo(_ id: UUID) {
        if engine.isGenerating { engine.stop() }
        input = ""
        statusLine = ""
        sessions.select(id)
    }

    private var attachSheet: some View {
        NavigationStack {
            Form {
                Section("图片") {
                    if let img = attachedImage {
                        HStack {
                            Image(uiImage: img).resizable().scaledToFit().frame(height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Spacer()
                            Button("移除") { attachedImage = nil }
                                .foregroundStyle(RMTheme.danger)
                        }
                    } else {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("图片 · 从相册选一张", systemImage: "photo.badge.plus")
                        }
                    }
                }
                Section("文件") {
                    if let f = attachedFile {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                                Text("来自 \(f.path)").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                            }
                            Spacer()
                            Button("移除") { attachedFile = nil }
                                .foregroundStyle(RMTheme.danger)
                        }
                    } else {
                        Button("从文件库选择文件") { showFilePick = true }
                    }
                }
                Section("Skill") {
                    if skillStore.skills.isEmpty {
                        Text("还没有 Skill。到「库 → Skill」点 + 上传 Skill.zip 即可。")
                            .font(.system(size: 12))
                            .foregroundStyle(RMTheme.textSub)
                    } else {
                        ForEach(skillStore.skills) { sk in
                            Button {
                                attachedSkillName = (attachedSkillName == sk.name) ? nil : sk.name
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sk.name).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                                        Text(sk.desc).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                    }
                                    Spacer()
                                    if attachedSkillName == sk.name {
                                        Image(systemName: "checkmark").foregroundStyle(RMTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("完成") { showAttach = false }
                }
            }
            .navigationTitle("附加内容")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showAttach = false } } }
        }
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                guard let data = data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    self.attachedImage = img
                    self.showAttach = false
                    self.photoItem = nil
                }
            }
        }
    }

    // MARK: - 发送

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard lock.acquire(.chat) else { return }

        // 拼真正发给模型的提问（小文本文件直接带正文，大的只报路径）
        var body = q
        var notice = ""
        if let f = attachedFile {
            if let d = FileStore.shared.readAt(f.path),
               let txt = String(data: d, encoding: .utf8), d.count <= 16384 {
                body += "\n\n[用户给的文件：\(f.name)]\n---\n\(txt)\n---\n"
                notice += "（附带文件：\(f.name)）"
            } else {
                notice += "（引用文件：\(f.name)，路径 \(f.path)）"
            }
        }
        if let s = attachedSkillName { notice += "（已附加 Skill：\(s)）" }
        if attachedImage != nil { notice += "（含一张图片）" }
        sessions.append(text: notice.isEmpty ? body : body + notice, isUser: true)
        input = ""

        guard let m = store.route(for: q) else {
            sessions.append(text: "（没有可用模型，去「库 → 模型」下载一个）", isUser: false)
            lock.release(.chat)
            return
        }
        let botId = UUID()
        sessions.append(ChatMessage(id: botId, text: "…", isUser: false))
        let finalPrompt = body
        statusLine = m.isMoE ? "命中 \(m.name)（MoE：只激活部分专家）" : "命中 \(m.name)，其余模型不加载"

        // 多轮历史（去掉刚加的占位回答）
        var history: [(Bool, String)] = []
        for msg in messages.dropLast() { history.append((msg.isUser, msg.text)) }

        // Max 模式：存档窗口拉到 1000k、只筛相关片段喂进去；平时用模型实际窗口
        let ctxTokens = maxMode
            ? min(device.tier.ctxTokens * 2, 32768)
            : device.tier.ctxTokens

        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LlamaEngine.shared.load(modelId: m.id,
                                             path: store.localPath(for: m),
                                             ctxTokens: ctxTokens,
                                             gpuLayers: device.tier.gpuLayers,
                                             sizeGB: m.sizeGB)
            if !ok {
                DispatchQueue.main.async {
                    sessions.replace(id: botId, with: "（模型没找到：去「库 → 模型」下载 \(m.name) 再试）")
                    statusLine = "模型未就绪"
                    lock.release(.chat)
                }
                return
            }

            var sys = """
            你是 RyMind 的本地助手，跑在 iPad 上、全程离线、没有联网。
            必须遵守：
            1. 用简体中文回答，简洁直接，一句话能说完就别说第二段。
            2. 数学和逻辑题：一步步算，算完才给最终答案。答案必须正确，1+1 就是 2，绝不能说成 3；
               算不出来就直说"我算不出来"，绝不编数字。
            3. 回答要扣题。用户问什么答什么，不要复述用户的问题，不要东拉西扯，不要胡诌名人和事实。
            4. 不确定或不知道的事，直接说不确定；不要编造。
            5. 代码给能直接跑的最小示例，不要写"此处省略"这类空话。
            6. 不要重复自己说过的话，不要堆废话。
            """
            if let s = attachedSkillName {
                sys += "\n\n你正在使用技能「\(s)」，严格按这个技能的说明办事。"
            }
            if attachedImage != nil {
                sys += "\n\n用户附了一张参考图，你要参照它的构图和配色来理解问题。"
            }

        var acc = ""
        let produced = LlamaEngine.shared.generate(brandHint: m.id, system: sys, prompt: finalPrompt,
                                                   history: history) { piece in
                acc += piece
                let snap = acc
                DispatchQueue.main.async { sessions.replace(id: botId, with: snap) }
            }

            DispatchQueue.main.async {
                var final = produced
                if final.isEmpty { final = "（这次没吐出东西，换个问题或换个模型试试；可在「高级」页把输出长度调大）" }
                sessions.replace(id: botId, with: final)
                device.usedGB = device.footprintGB
                statusLine = ""
                lock.release(.chat)
            }
        }
    }
}
