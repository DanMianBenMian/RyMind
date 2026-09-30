import SwiftUI

enum LibSegment: String, CaseIterable, Identifiable {
    case models = "模型"
    case skills = "Skill"
    case files  = "文件"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .models: return "cpu"
        case .skills: return "square.stack.3d.down.right"
        case .files:  return "doc.on.doc"
        }
    }
}

struct LibraryView: View {
    @State private var segment: LibSegment = .models

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("库")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(RMTheme.text)
                Spacer()
                Button { } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RMTheme.accent)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Picker("", selection: $segment) {
                ForEach(LibSegment.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    switch segment {
                    case .models: modelList
                    case .skills: skillList
                    case .files:  fileList
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .background(RMTheme.bg)
    }

    private func row(_ title: String, _ sub: String, _ badge: String, _ color: SwiftUI.Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                Text(sub).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
            }
            Spacer()
            Text(badge).font(.system(size: 11)).foregroundStyle(color)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var modelList: some View {
        Group {
            row("Qwen2.5-1.5B-Q5", "1.1 GB · 已就绪", "使用中", RMTheme.accent)
            row("Llama-3.2-1B-Q4", "0.8 GB · 已下载", "切换", RMTheme.textSub)
            row("Gemma-2-2B-Q4", "1.6 GB · 下载中 62%", "暂停", RMTheme.warn)
        }
    }

    private var skillList: some View {
        Group {
            row("probe-report", "已解压 · 3 个脚本", "已启用", RMTheme.accent)
            row("kernel-audit", "已解压 · 1 个脚本", "未启用", RMTheme.textSub)
        }
    }

    private var fileList: some View {
        Group {
            row("/workspace/chat-7f2a", "3 个文件 · 1.2 MB", "当前", RMTheme.accent)
            row("/workspace/chat-3c91", "5 个文件 · 640 KB", "打开", RMTheme.textSub)
        }
    }
}
