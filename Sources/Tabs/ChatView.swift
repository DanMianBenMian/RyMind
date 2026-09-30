import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct ChatView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var device: DeviceProfile

    @State private var input = ""
    @State private var messages: [ChatMessage] = [
        .init(text: "帮我把上周的探针结果整理成报告", isUser: true),
        .init(text: "已读取工作空间 3 个文件，正在生成…", isUser: false),
        .init(text: "加上内存占用那段", isUser: true)
    ]
    @State private var usedK: Double = 12.4
    @State private var maxMode = false

    /// 存档容量（Max 模式 1000k）；实际送进模型的是检索出的片段
    private var archiveK: Double { maxMode ? 1000 : Double(device.tier.ctxTokens) / 1024.0 }
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
                Button { } label: { Label("添加 Skill", systemImage: "square.stack.3d.down.right") }
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

    private func send() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 与生图互斥
        guard lock.acquire(.chat) else { return }
        messages.append(.init(text: input, isUser: true))
        input = ""
        // TODO: 接推理引擎（含关键词筛 + 档位自适应）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            messages.append(.init(text: "（推理引擎尚未接入）", isUser: false))
            lock.release(.chat)
        }
    }
}
