import SwiftUI
import PhotosUI
import UIKit

/// 从文件库选中的文件（path 是 unix 路径）
struct PickedFile: Identifiable {
    let path: String
    let name: String
    var id: String { path + "/" + name }
}

/// 文件库浏览选择器（复用 FileStore 的目录树）——**可以多选**，选完点「加入」一起带进对话
private struct FilePickerSheet: View {
    @EnvironmentObject private var fs: FileStore
    let onPick: ([(String, String)]) -> Void

    @State private var picked = Set<String>()

    var body: some View {
        NavigationStack {
            List {
                if fs.path != "/" {
                    Button { fs.up(); picked.removeAll() } label: {
                        Label("上一级", systemImage: "folder")
                    }
                }
                Section("当前目录 · 点文件选中（可多选）") {
                    ForEach(fs.entries) { e in
                        if e.isDir {
                            NavigationLink {
                                FilePickerSheet(onPick: onPick)
                            } label: {
                                Label(e.name, systemImage: "folder")
                            }
                        } else {
                            Button {
                                if picked.contains(e.name) { picked.remove(e.name) }
                                else { picked.insert(e.name) }
                            } label: {
                                HStack(spacing: 8) {
                                    Label(e.name, systemImage: "doc")
                                    Spacer()
                                    if picked.contains(e.name) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(RMTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(RMTheme.rail)
            .navigationTitle(picked.isEmpty ? "从文件库选" : "已选 \(picked.count) 个")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { fs.goRoot(); onPick([]) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入（\(picked.count)）") {
                        let items = fs.entries.filter { !$0.isDir && picked.contains($0.name) }
                            .map { (fs.path, $0.name) }
                        onPick(items)
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
        .onAppear { fs.refresh(); picked.removeAll() }
    }
}

/// 键盘弹起时把弹层收掉，避免点输入框冒出会话选择器打断键盘。
/// 用 addObserver 而不是 NotificationCenter.publisher（后者 iOS17+ 才有，当前 SDK 没有）。
final class RMKeyboardGuard: ObservableObject {
    @Published var keyboardUp = false
    /// 键盘高度（用来把输入框顶上来，别被键盘挡住）
    @Published var height: CGFloat = 0
    @Published var animation: Double = 0.25
    private var token: NSObjectProtocol?
    private var hideToken: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main) { [weak self] n in
                guard let self else { return }
                if let rect = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
                    self.height = rect.height
                }
                if let dur = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue {
                    self.animation = dur
                }
                self.keyboardUp = true
            }
        hideToken = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.keyboardUp = false
                self?.height = 0
            }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        if let hideToken { NotificationCenter.default.removeObserver(hideToken) }
    }
}

struct ChatView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var device: DeviceProfile
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var engine: LlamaEngine
    @EnvironmentObject private var skillStore: SkillStore
    @EnvironmentObject private var fs: FileStore

    private let landscape: Bool

    @State private var input = ""
    @State private var maxMode = false
    @State private var statusLine = ""
    @State private var showSessions = false
    @State private var showAttach = false
    // ⚠️ 三个附件都改成数组：图能多选、文件能多选、技能也能多选
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachedImages: [UIImage] = []
    @State private var attachedFiles: [PickedFile] = []
    @State private var attachedSkills: [String] = []
    @State private var showFilePick = false
    @State private var pickToken: Int = 0     // 每次发出后自增，逼 onChange 再触发一次

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
            // 键盘弹起时把内容顶上来：键盘高度减去系统已经让出来的安全区，
            // 这样不管 SwiftUI 有没有自动避让，都不会被挡住也不会顶过头
            GeometryReader { g in
                mainColumn.padding(.bottom, max(0, kb.height - g.safeAreaInsets.bottom))
            }
        }
        .background(RMTheme.bg)
        .animation(.easeOut(duration: kb.animation), value: kb.keyboardUp)
        .sheet(isPresented: Binding(get: { self.showSessions && !self.kb.keyboardUp },
                                    set: { v in self.showSessions = v; self.kb.keyboardUp = false })) {
            sessionSheet
        }
        .sheet(isPresented: $showAttach) { attachSheet }
        .sheet(isPresented: Binding(get: { self.showFilePick && !self.kb.keyboardUp },
                                    set: { v in self.showFilePick = v; self.kb.keyboardUp = false })) {
            FilePickerSheet { items in
                let add = items.filter { t in !self.attachedFiles.contains { $0.path == t.0 && $0.name == t.1 } }
                for it in add { self.attachedFiles.append(PickedFile(path: it.0, name: it.1)) }
                if !add.isEmpty { self.showFilePick = false }
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
        HStack(alignment: .bottom) {
            if m.isUser { Spacer(minLength: 40) }
            VStack(alignment: m.isUser ? .trailing : .leading, spacing: 6) {
                // 附件先渲染：图出缩略图、文件出卡片，不再写成一行路径文字
                ForEach(m.attachments) { at in
                    attachmentView(at, user: m.isUser)
                }
                if !m.text.isEmpty {
                    Text(m.text)
                        .font(.system(size: 13))
                        .foregroundStyle(m.isUser ? Color(hex: 0xE8F5F0) : Color(hex: 0xDCDCE0))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(m.isUser ? RMTheme.user : RMTheme.bot)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if !m.isUser { Spacer(minLength: 40) }
        }
    }

    /// 附件渲染：图片出缩略图，文件出可点的卡片（点开直接跳到文件库那个路径）
    @ViewBuilder
    private func attachmentView(_ at: ChatAttachment, user: Bool) -> some View {
        switch at.kind {
        case .image:
            if let img = UIImage(data: at.data ?? Data()) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(user ? Color(hex: 0xE8F5F0).opacity(0.5) : RMTheme.accent, lineWidth: 1))
            }
        case .file:
            HStack(spacing: 8) {
                Image(systemName: "doc.fill").font(.system(size: 13)).foregroundStyle(RMTheme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(at.name).font(.system(size: 12)).foregroundStyle(RMTheme.text).lineLimit(1)
                    Text(at.sizeBytes > 0 ? "\(at.sizeBytes) 字节" : "文件").font(.system(size: 10)).foregroundStyle(RMTheme.textSub)
                }
                Spacer()
                // 点一下直接跳到文件库定位过去
                Button { showFilePick = false; showAttach = false; fs.enterPath(at.path) } label: {
                    Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(RMTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RMTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .skill:
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(RMTheme.accent)
                Text("技能：\(at.name)").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RMTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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

            let hasAttach = !attachedImages.isEmpty || !attachedFiles.isEmpty || !attachedSkills.isEmpty
            if hasAttach {
                Menu {
                    if !attachedImages.isEmpty {
                        Button("移除全部图片（\(attachedImages.count)）") { attachedImages.removeAll(); photoItems.removeAll(); pickToken += 1 }
                    }
                    if !attachedFiles.isEmpty {
                        Button("移除全部文件（\(attachedFiles.count)）") { attachedFiles.removeAll() }
                    }
                    if !attachedSkills.isEmpty {
                        Button("移除全部技能（\(attachedSkills.count)）") { attachedSkills.removeAll() }
                    }
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
                Section("图片 · 可多选（最多 6 张，发出后直接显示在聊天里）") {
                    if attachedImages.isEmpty {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                            Label("从相册选图片", systemImage: "photo.badge.plus")
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(attachedImages.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img)
                                        .resizable().scaledToFit().frame(width: 78, height: 78)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                        Button("清空图片") { attachedImages.removeAll(); photoItems.removeAll(); pickToken += 1 }
                            .foregroundStyle(RMTheme.danger)
                    }
                }
                Section("文件 · 可多选（从工作空间挑，或再往里翻目录）") {
                    if attachedFiles.isEmpty {
                        Button("从文件库选择文件") { showFilePick = true }
                    } else {
                        ForEach(attachedFiles) { f in
                            HStack {
                                Label(f.name, systemImage: "doc")
                                Spacer()
                                Button("移除") { attachedFiles.removeAll { $0.id == f.id } }
                                    .foregroundStyle(RMTheme.danger)
                            }
                        }
                        Button("再加文件") { showFilePick = true }
                    }
                }
                Section("技能 · 可多选（每条都会写进本次的指令里）") {
                    if skillStore.skills.isEmpty {
                        Text("还没有 Skill。到「库 → Skill」点 + 上传 Skill.zip 即可。")
                            .font(.system(size: 12))
                            .foregroundStyle(RMTheme.textSub)
                    } else {
                        ForEach(skillStore.skills) { sk in
                            Button {
                                if attachedSkills.contains(sk.name) {
                                    attachedSkills.removeAll { $0 == sk.name }
                                } else {
                                    attachedSkills.append(sk.name)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sk.name).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                                        Text(sk.desc).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                    }
                                    Spacer()
                                    if attachedSkills.contains(sk.name) {
                                        Image(systemName: "checkmark").foregroundStyle(RMTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    let any = !attachedImages.isEmpty || !attachedFiles.isEmpty || !attachedSkills.isEmpty
                    Button(any ? "完成（已附加 \(attachedImages.count) 图 · \(attachedFiles.count) 文件 · \(attachedSkills.count) 技能）"
                               : "完成") { showAttach = false }
                        .foregroundStyle(any ? RMTheme.accent : RMTheme.textSub)
                }
            }
            .navigationTitle("附加内容")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showAttach = false } } }
        }
        // 多选相册：photoItems 每次选完会被清空，这里用 pickToken 强制再触发一次
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                var got: [UIImage] = []
                for it in items {
                    guard let data = try? await it.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { continue }
                    got.append(img)
                }
                if !got.isEmpty {
                    await MainActor.run { self.attachedImages.append(contentsOf: got) }
                }
                await MainActor.run { self.photoItems = []; self.pickToken += 1 }
            }
        }
    }

    // MARK: - 发送

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 没文字但带了图/文件/技能，也算一条消息（之前空发送直接被挡掉）
        guard !q.isEmpty || !attachedImages.isEmpty || !attachedFiles.isEmpty || !attachedSkills.isEmpty else { return }
        guard lock.acquire(.chat) else { return }

        // 附件：真对象进聊天窗口（图出缩略图、文件出卡片），不走"把路径写成文字"那套
        var atts: [ChatAttachment] = []
        for img in attachedImages {
            let png = img.pngData()
            // 超过 4 MB 就不存进会话存档了，免得 sessions.json 撑爆
            if let png, png.count <= 4 * 1024 * 1024 {
                atts.append(ChatAttachment(kind: .image, name: "图片", data: png, size: Int64(png.count)))
            }
        }
        for f in attachedFiles {
            let size = fs.readAt(f.path)?.count ?? 0
            atts.append(ChatAttachment(kind: .file, name: f.name, path: f.path, size: Int64(size)))
        }
        for s in attachedSkills {
            atts.append(ChatAttachment(kind: .skill, name: s))
        }

        // 正文：只有纯文本提问；附件靠这行简短清单告诉模型"有几张图/几个文件"，
        // 不把图片像素和文件内容整段塞进 prompt（也别再写成一大坨中文说明）
        var body = q
        let imgN = atts.filter { $0.kind == .image }.count
        let fileN = atts.filter { $0.kind == .file }.count
        let skillN = atts.filter { $0.kind == .skill }.count
        var meta = ""
        if imgN > 0 { meta += "用户附了 \(imgN) 张图片，你要参照它们的构图和内容理解问题；"; }
        if fileN > 0 { meta += "用户附了 \(fileN) 个文件（见聊天里的文件卡片）；"; }
        if skillN > 0 { meta += "本次启用了 \(skillN) 个技能：\(attachedSkills.joined(separator: "、"))，按它们的要求办事；"; }
        if !meta.isEmpty { body = body.isEmpty ? "" : body; body += "\n\n[附件说明] \(meta)" }

        sessions.append(text: body, isUser: true, attachments: atts)
        input = ""
        // 发完清掉，免得下一轮又带上
        attachedImages.removeAll(); attachedFiles.removeAll(); attachedSkills.removeAll()
        photoItems.removeAll(); pickToken += 1

        guard let m = store.route(for: q.isEmpty ? "（用户刚才发了附件）" : q) else {
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

        // ⚠️ Max 模式**不再把推理窗口翻倍**：那才是"一开 Max 就变高负载/卡"的原因。
        // 它只影响上下文显示（按 1000k 存档窗口算）和历史筛选，推理窗口照旧。
        let ctxTokens = device.tier.ctxTokens
        let gpu = device.metalEnabled ? device.tier.gpuLayers : 0

        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LlamaEngine.shared.load(modelId: m.id,
                                             path: store.localPath(for: m),
                                             ctxTokens: ctxTokens,
                                             gpuLayers: gpu,
                                             sizeGB: m.sizeGB)
            if !ok {
                DispatchQueue.main.async {
                    sessions.replace(id: botId, with: "（模型没找到：去「库 → 模型」下载 \(m.name) 再试）")
                    statusLine = "模型未就绪"
                    lock.release(.chat)
                }
                return
            }

            // ⚠️ 这条 system prompt 之前第 5 条写着"代码给能直接跑的最小示例"，
            // 结果不管问什么都吐代码块（"莫名奇妙的代码"就是这么来的）。现在改成：默认不输出代码。
            var sys = """
            你是 RyMind 的本地助手，跑在一台 iPad 上、全程离线、没有联网。
            必须遵守，按优先级从上到下：
            1. 用简体中文、Natural、口语化地回答。像人在聊天，不要客套、不要列表堆砌。
            2. 默认**不要输出代码**。只有用户明确要求写代码、或者不写代码就没法回答时，才给一小段代码。
               不许出现"以下是代码"、"示例代码如下"、"此处省略"这类空话。
            3. 回答要扣题：用户问什么答什么，别复述用户的问题，别东拉西扯，别编造名人和事实。
               一次回答控制在三五句话内，简单问题一句话说完。
            4. 数学和逻辑题：一步步算，算完才给最终答案。1+1 就是 2，绝不能说成 3；
               算不出来就直说"我算不出来"，绝不编数字。
            5. 不确定或不知道的事，直接说不确定；不要编造。
            6. 不要重复自己说过的话，不要堆废话，不要每句都用同样的开头。
            """
            if skillN > 0 {
                sys += "\n\n本次启用了技能「\(attachedSkills.joined(separator: "、"))」，你要参照这些技能的要求回答问题。"
            }
            if imgN > 0 {
                sys += "\n\n用户这次附了 \(imgN) 张图片（聊天记录里有缩略图），你要参照图片内容来理解问题；图片看不清就说看不清，别瞎描述。"
            }
            if fileN > 0 {
                sys += "\n\n用户这次附了 \(fileN) 个文件，但你是纯文本模型、读不到文件内容，别假装读过它们；只看用户下面的文字提问作答。"
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
