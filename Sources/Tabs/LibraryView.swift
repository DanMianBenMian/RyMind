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
    @EnvironmentObject private var skillStore: SkillStore

    @State private var segment: LibSegment = .models
    @State private var showAdd = false
    @State private var addMode = 0              // 0 = GGUF 直链, 1 = 上传模型文件
    @State private var newName = ""
    @State private var newURL = ""
    @State private var showModelPick = false
    @State private var showSkillPick = false
    @State private var skillNote = ""
    @State private var showSkillDoc = false
    @State private var docText = ""
    @State private var modelNote = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $segment) {
                ForEach(LibSegment.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            if segment == .files {
                FilesView()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        switch segment {
                        case .models: modelList
                        case .skills: skillList
                        case .files:  EmptyView()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(RMTheme.bg)
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(isPresented: $showModelPick) { DocPicker { url in
            let id = store.addUploaded(from: url)
            modelNote = "导入完成（Models/\(id).gguf），回到模型列表就能切换使用"
        } }
        .sheet(isPresented: $showSkillPick) { DocPicker { url in skillNote = skillStore.importSkill(from: url) } }
        .sheet(isPresented: $showSkillDoc) { skillDocSheet }
    }

    private var header: some View {
        HStack {
            Text("库").font(.system(size: 15, weight: .medium)).foregroundStyle(RMTheme.text)
            Spacer()
            // 加号按段走：模型 = 加自定义模型；Skill = 上传 Skill 文件；文件段由文件页自己带 +
            if segment != .files {
                Button { addTapped() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(RMTheme.accent)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func addTapped() {
        if segment == .skills { showSkillPick = true }
        else { showAdd = true }
    }

    // MARK: - 模型

    private var modelList: some View {
        VStack(spacing: 8) {
            if !modelNote.isEmpty {
                Text(modelNote)
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    // MARK: - Skill

    private var skillList: some View {
        VStack(spacing: 8) {
            if !skillNote.isEmpty {
                Text(skillNote)
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if skillStore.skills.isEmpty {
                card(title: "还没有 Skill",
                     sub: "点右上角 + 选一个 Skill.zip，上传后会自动解压，之后就能在对话里点 + 附加。")
            }
            ForEach(skillStore.skills) { sk in skillRow(sk) }
        }
    }

    private func skillRow(_ sk: RMSkill) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sk.name).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                    Text(sk.desc).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button(sk.enabled ? "停用" : "启用") { skillStore.toggle(sk.id) }
                        .font(.system(size: 12)).foregroundStyle(RMTheme.accent)
                    Button("删除") { skillStore.remove(sk.id) }
                        .font(.system(size: 12)).foregroundStyle(RMTheme.danger)
                }
            }
            Button("看 SKILL.md") {
                if let u = skillStore.entryURL(for: sk), let t = try? String(contentsOf: u, encoding: .utf8) {
                    docText = t
                    showSkillDoc = true
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(RMTheme.textSub)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var skillDocSheet: some View {
        NavigationStack {
            ScrollView {
                Text(docText)
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.text)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RMTheme.bg)
            .navigationTitle("Skill 说明")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSkillDoc = false } } }
        }
    }

    // MARK: - 添加自定义模型：直链 / 上传文件

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("方式") {
                    Picker("", selection: $addMode) {
                        Text("GGUF 直链").tag(0)
                        Text("上传模型文件").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if addMode == 0 {
                    Section("模型名称") {
                        TextField("例如 Qwen2.5-3B-Instruct", text: $newName)
                    }
                    Section("GGUF 直链") {
                        TextField("https://...", text: $newURL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("上传模型文件") {
                        Text("从本机选一个 .gguf（或改过名的模型文件），它会拷进 Models 目录，直接就能切换使用。")
                            .font(.system(size: 12))
                            .foregroundStyle(RMTheme.textSub)
                        Button("选择模型文件…") { showModelPick = true }
                            .foregroundStyle(RMTheme.accent)
                    }
                    Section("（可选）模型名称") {
                        TextField("留空就用文件名", text: $newName)
                    }
                }

                Section {
                    Button("添加") {
                        if addMode == 0 {
                            guard !newName.isEmpty, !newURL.isEmpty else { return }
                            store.addCustom(name: newName, url: newURL)
                        }
                        showAdd = false
                        newName = ""
                        newURL = ""
                    }
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

    private func card(title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13)).foregroundStyle(RMTheme.text)
            Text(sub).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
