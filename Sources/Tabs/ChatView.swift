import SwiftUI
import PhotosUI

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

    init(landscape: Bool) { self.landscape = landscape }

    private var windowK: Double {
        (maxMode ? 1000.0 : Double(device.tier.ctxTokens)) / 1024.0
    }
    private var usedK: Double { Double(engine.ctxUsed) / 1024.0 }
    private var messages: [ChatMessage] { sessions.messages }

    var body: some View {
        HStack(spacing: 0) {
            if landscape { sessionSidebar }
            mainColumn
        }
        .background(RMTheme.bg)
        .sheet(isPresented: $showSessions) { sessionSheet }
        .sheet(isPresented: $showAttach) { attachSheet }
    }

    // MARK: - 主区

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { m in bubble(m) }
                    if messages.isEmpty {
                        Text("开始一个新话题吧。左下角可以看到所有对话记录。")
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
                Text(String(format: "上下文已用 %.1fk / %.0fk", usedK, windowK))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
            }
            ProgressView(value: min(usedK, windowK), total: max(windowK, 1))
                .tint(RMTheme.accent)
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

            // 已附加的东西，点一下取消
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

            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x0B1F1B))
                    .frame(width: 30, height: 30)
                    .background(RMTheme.accent)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RMTheme.rail)
    }

    // MARK: - 会话侧栏 / 弹层

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("对话记录").font(.system(size: 13, weight: .medium)).foregroundStyle(RMTheme.text)
                Spacer()
                Button { sessions.makeCurrentSession(title: "新对话") } label: {
                    Image(systemName: "square.compose")
                        .font(.system(size: 13))
                        .foregroundStyle(RMTheme.accent)
                }
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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) { ForEach(sessions.sessions) { sessionRow($0, compact: true) } }
                        .padding(12)
                }
            }
            .background(RMTheme.rail)
            .navigationTitle("对话记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("新建") { sessions.makeCurrentSession(title: "新对话"); showSessions = false }
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
                if !compact {
                    Button {
                        withAnimation { sessions.delete(s.id) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(RMTheme.textSub)
                    }
                }
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
        .onTapGesture { sessions.select(s.id); if compact { showSessions = false } }
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
                            Label("从相册选一张参考图", systemImage: "photo.badge.plus")
                        }
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
                                if attachedSkillName == sk.name {
                                    attachedSkillName = nil
                                } else {
                                    attachedSkillName = sk.name
                                }
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

        var notice = ""
        if let s = attachedSkillName { notice += "（已附加 Skill：\(s)）" }
        if attachedImage != nil { notice += "（含一张参考图）" }
        sessions.append(text: notice.isEmpty ? q : q + notice, isUser: true)
        input = ""

        guard let m = store.route(for: q) else {
            sessions.append(text: "（没有可用模型，去「库 → 模型」下载一个）", isUser: false)
            lock.release(.chat)
            return
        }
        let botId = UUID()
        sessions.append(ChatMessage(id: botId, text: "…", isUser: false))
        statusLine = m.isMoE ? "命中 \(m.name)（MoE：只激活部分专家）" : "命中 \(m.name)，其余模型不加载"

        let brand = m.id.lowercased().contains("llama") ? "llama"
                  : m.id.lowercased().contains("gemma") ? "gemma" : "qwen"

        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LlamaEngine.shared.load(modelId: m.id,
                                             path: store.localPath(for: m),
                                             ctxTokens: device.tier.ctxTokens,
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

            var sys = "你是 RyMind 的本地助手，运行在 iPad 上、全程离线。回答简洁直接，用中文。"
            if let s = attachedSkillName {
                sys += "\n\n你正在使用技能「\(s)」，按它的说明办事。"
            }
            if attachedImage != nil {
                sys += "\n\n用户附带了一张参考图，参照它的构图/配色来理解问题。"
            }

            var acc = ""
            let produced = LlamaEngine.shared.generate(brandHint: m.id, system: sys, prompt: q, maxTokens: 256) { piece in
                acc += piece
                let snap = acc
                DispatchQueue.main.async { sessions.replace(id: botId, with: snap) }
            }

            DispatchQueue.main.async {
                var final = produced
                if final.isEmpty { final = "（这次没吐出东西，换个问题或换个模型试试）" }
                sessions.replace(id: botId, with: final)
                device.usedGB = device.footprintGB
                statusLine = ""
                lock.release(.chat)
            }
        }
    }
}
