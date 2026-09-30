import SwiftUI

struct ChatMessage: Identifiable {
    let id: UUID
    var text: String
    let isUser: Bool

    init(id: UUID = UUID(), text: String, isUser: Bool) {
        self.id = id
        self.text = text
        self.isUser = isUser
    }
}

struct ChatView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var device: DeviceProfile
    @EnvironmentObject private var store: ModelStore

    @State private var input = ""
    @State private var messages: [ChatMessage] = [
        .init(text: "帮我把上周的探针结果整理成报告", isUser: true),
        .init(text: "已读取工作空间 3 个文件，正在生成…", isUser: false),
        .init(text: "加上内存占用那段", isUser: true)
    ]
    @State private var usedK: Double = 0
    @State private var maxMode = false
    @State private var statusLine = "未加载模型"

    private var windowK: Double { Double(device.tier.ctxTokens) / 1024.0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { m in bubble(m) }
                }
                .padding(12)
            }
            composer
        }
        .background(RMTheme.bg)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
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
            Text(statusLine)
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
            Menu {
                Button { } label: { Label("添加图片", systemImage: "photo") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RMTheme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
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

    private func append(_ id: UUID, _ s: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text += s
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard lock.acquire(.chat) else { return }

        messages.append(ChatMessage(text: q, isUser: true))
        input = ""

        // 任务路由：只挑命中的那一个模型去加载
        guard let m = store.route(for: q) else {
            messages.append(ChatMessage(text: "（没有可用模型，去「库 → 模型」下载一个）", isUser: false))
            lock.release(.chat)
            return
        }
        if m.isMoE {
            statusLine = "命中 \(m.name)（MoE：每次只激活部分专家）"
        } else {
            statusLine = "命中 \(m.name)，其余模型未加载"
        }

        let botId = UUID()
        messages.append(ChatMessage(id: botId, text: "", isUser: false))

        let ctxTokens = device.tier.ctxTokens
        let gpuLayers = device.tier.gpuLayers
        let path = store.localPath(for: m)

        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LlamaEngine.shared.load(modelId: m.id,
                                             path: path,
                                             ctxTokens: ctxTokens,
                                             gpuLayers: gpuLayers,
                                             sizeGB: m.sizeGB)
            if !ok {
                DispatchQueue.main.async {
                    append(botId, "（模型文件不存在，去「库 → 模型」下载 \(m.name) 后重试）")
                    statusLine = "模型未下载"
                    lock.release(.chat)
                }
                return
            }

            DispatchQueue.main.async {
                device.usedGB = LlamaEngine.shared.loadedSizeGB
                statusLine = "\(m.name) 已加载（mmap 惰性载入，未跑到部分可被回收）"
            }

            _ = LlamaEngine.shared.generate(prompt: q, maxTokens: 256) { piece in
                DispatchQueue.main.async {
                    append(botId, piece)
                }
            }

            DispatchQueue.main.async {
                usedK = Double(LlamaEngine.shared.activeTokens) / 1024.0
                device.usedGB = device.footprintGB
                statusLine = "完成 · 仍只加载 \(m.name)"
                lock.release(.chat)
            }
        }
    }
}
