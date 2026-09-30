import SwiftUI

enum LibSegment: String, CaseIterable, Identifiable {
    case models = "模型"
    case skills = "Skill"
    case files  = "文件"

    var id: String { rawValue }
}

struct LibraryView: View {
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var dl: ModelDownloader

    @State private var segment: LibSegment = .models
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $segment) {
                ForEach(LibSegment.allCases) { s in Text(s.rawValue).tag(s) }
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
                .padding(.bottom, 12)
            }
        }
        .background(RMTheme.bg)
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var header: some View {
        HStack {
            Text("库").font(.system(size: 15, weight: .medium)).foregroundStyle(RMTheme.text)
            Spacer()
            Button { showAdd = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RMTheme.accent)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 模型

    private var modelList: some View {
        VStack(spacing: 8) {
            if !dl.lastMessage.isEmpty {
                Text(dl.lastMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(store.llmModels) { m in modelRow(m) }
        }
    }

    private func modelRow(_ m: RMModel) -> some View {
        let p = dl.progress[m.id] ?? 0
        let isDownloading = dl.downloadingIds.contains(m.id)
        let paused = m.state == .downloading

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.label)
                        .font(.system(size: 13))
                        .foregroundStyle(RMTheme.text)
                    Text("\(m.brand) · \(m.sizeLabel) · \(m.state.rawValue)")
                        .font(.system(size: 11))
                        .foregroundStyle(RMTheme.textSub)
                    if m.isMoE {
                        Text("MoE：每次只激活部分专家，最省内存")
                            .font(.system(size: 11))
                            .foregroundStyle(RMTheme.accent)
                    }
                }
                Spacer()
                actions(for: m, isDownloading: isDownloading, paused: paused)
            }

            if isDownloading || paused {
                ProgressView(value: p).tint(RMTheme.accent)
                Text(String(format: "%.1f%%", p * 100))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func actions(for m: RMModel, isDownloading: Bool, paused: Bool) -> some View {
        if isDownloading {
            HStack(spacing: 12) {
                Button("暂停") { dl.pause(m.id) }
                Button("取消") { dl.cancel(m.id) }
            }
            .font(.system(size: 12))
        } else if paused {
            HStack(spacing: 12) {
                Button("继续") { dl.resume(m.id) }
                Button("取消") { dl.cancel(m.id) }
            }
            .font(.system(size: 12))
        } else if m.state == .ready {
            HStack(spacing: 12) {
                if store.currentLLMId == m.id {
                    Text("使用中").foregroundStyle(RMTheme.accent)
                } else {
                    Button("切换") { store.select(m) }.foregroundStyle(RMTheme.accent)
                }
                Button("删除") { store.deleteLocal(m) }.foregroundStyle(RMTheme.danger)
            }
            .font(.system(size: 12))
        } else if m.hasSource {
            Button("下载") { dl.start(m) }
                .font(.system(size: 12))
                .foregroundStyle(RMTheme.accent)
        } else {
            Text("需手动加链接").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
        }
    }

    // MARK: - 其余两段（占位）

    private var skillList: some View {
        VStack(spacing: 8) {
            row("probe-report", "已解压 · 3 个脚本", "已启用", RMTheme.accent)
            row("kernel-audit", "已解压 · 1 个脚本", "未启用", RMTheme.textSub)
        }
    }

    private var fileList: some View {
        VStack(spacing: 8) {
            row("/workspace/chat-7f2a", "3 个文件 · 1.2 MB", "当前", RMTheme.accent)
            row("/workspace/chat-3c91", "5 个文件 · 640 KB", "打开", RMTheme.textSub)
        }
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

    // MARK: - 自定义添加

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("模型名称") {
                    TextField("例如 Qwen2.5-3B-Instruct", text: $newName)
                }
                Section("GGUF 直链") {
                    TextField("https://...", text: $newURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                }
                Section {
                    Button {
                        guard !newName.isEmpty, !newURL.isEmpty else { return }
                        store.addCustom(name: newName, url: newURL)
                        showAdd = false
                        newName = ""
                        newURL = ""
                    } label: { Text("添加") }
                }
            }
            .navigationTitle("添加自定义模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
            }
        }
    }
}
