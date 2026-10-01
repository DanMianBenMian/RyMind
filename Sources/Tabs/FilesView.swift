import SwiftUI
import JavaScriptCore

// MARK: - 文件浏览器

private let TimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

struct FilesView: View {
    @EnvironmentObject private var fs: FileStore

    @State private var showPicker = false
    @State private var detail: RMFileEntry?
    @State private var showTerminal = false
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var showNewFile = false
    @State private var fileName = ""
    // 多选：点文件 = 选中/取消选中；点文件夹 = 进去。工具栏同时显示「已选 N 项」
    @State private var selected = Set<String>()
    @State private var multiMode = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            toolbar
            list
        }
        .background(RMTheme.bg)
        .sheet(isPresented: $showPicker) { DocPicker { url in fs.upload(from: url) } }
        .sheet(item: $detail) { FileDetailView(item: $0) }
        .sheet(isPresented: $showTerminal) { TerminalView() }
        // 批量删除确认（删了就找不回来，别手抖）
        .alert("删除 \(selected.count) 项？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                fs.remove(names: Array(selected))
                selected.removeAll()
                multiMode = false
            }
            Button("取消", role: .cancel) { selected.removeAll() }
        } message: {
            Text("这些文件和文件夹会被永久删掉，没法撤销。")
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $folderName)
            Button("创建") {
                fs.makeDir(folderName)
                folderName = ""
            }
            Button("取消", role: .cancel) { folderName = "" }
        } message: {
            Text("直接写名字，会建在当前目录下")
        }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("文件名（如 笔记.txt）", text: $fileName)
            Button("创建并编辑") {
                let n = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                fs.createFile(at: fs.path, name: n, text: "")
                fileName = ""
            }
            Button("取消", role: .cancel) { fileName = "" }
        } message: {
            Text("会建在当前目录下，建完自动打开让你写。空着的文件名不会建。")
        }
        .onAppear { if fs.entries.isEmpty { fs.refresh() } }
        .toast(fs.message)
    }

    // 面包屑：每一节都能点，点哪回哪，点 /rmind 就是回根目录
    private var pathBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(pathSegments.enumerated()), id: \.offset) { i, seg in
                        Button {
                            if seg.1 == "/" { fs.goRoot() } else { fs.enterPath(seg.1) }
                        } label: {
                            Text(seg.0)
                                .font(.system(size: 11, weight: i == pathSegments.count - 1 ? .medium : .regular))
                                .foregroundStyle(i == pathSegments.count - 1 ? RMTheme.accent : RMTheme.textSub)
                        }
                        .buttonStyle(.plain)
                        if i < pathSegments.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(RMTheme.textSub)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    if fs.path == "/" { fs.goRoot() } else { fs.up() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: fs.path == "/" ? "house.fill" : "chevron.left")
                            .font(.system(size: 12))
                        Text(fs.path == "/" ? "根目录" : "上一级")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(RMTheme.accent)
                }
                Spacer()
                Text("\(fs.entries.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RMTheme.rail)
    }

    private var pathSegments: [(String, String)] {
        let parts = fs.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return [("/rmind", "/")] }
        var out: [(String, String)] = [("/rmind", "/")]
        var acc = ""
        for p in parts { acc += "/" + p; out.append((p, acc)) }
        return out
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("上传文件") { showPicker = true }
                // 不一定要上传：直接在这儿建新文件，建完立刻点开写
                Button("新建文件") { showNewFile = true }
                Button("新建文件夹") { showNewFolder = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RMTheme.accent)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(RMTheme.accent, lineWidth: 1))
            }

            // 多选开关（移动/复制那两个按钮已经删掉，用「选」代替）
            Button {
                multiMode.toggle()
                if !multiMode { selected.removeAll() }
            } label: {
                Label("选", systemImage: multiMode ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(multiMode ? RMTheme.accent : RMTheme.text)
            }

            Button(action: { fs.paste() }) {
                Text("粘贴").font(.system(size: 12)).foregroundStyle(fs.hasClipboard ? RMTheme.text : RMTheme.textSub)
            }
            .disabled(!fs.hasClipboard)

            if multiMode {
                Button("全选") { selected = Set(fs.entries.map { $0.name }) }
                    .font(.system(size: 12))
                Button("清空") { selected.removeAll() }
                    .font(.system(size: 12))
                Button("删除选中（\(selected.count)）") { confirmDelete = true }
                    .font(.system(size: 12))
                    .foregroundStyle(selected.isEmpty ? RMTheme.textSub : RMTheme.danger)
                    .disabled(selected.isEmpty)
            }
            Spacer()
            Text(multiMode && !selected.isEmpty ? "已选 \(selected.count) 项" : "")
                .font(.system(size: 11))
                .foregroundStyle(RMTheme.accent)
            Button { showTerminal = true } label: {
                Label("终端", systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
            }
            Button { fs.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(RMTheme.textSub)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RMTheme.rail)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(fs.entries) { item in
                    fileRow(item)
                }
            }
            .padding(12)
        }
    }

    private func fileRow(_ item: RMFileEntry) -> some View {
        let picked = selected.contains(item.name)
        HStack(spacing: 10) {
            if multiMode {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(picked ? RMTheme.accent : RMTheme.textSub)
                    .frame(width: 18)
            }
            Image(systemName: item.isDir ? "folder.fill" : "doc.fill")
                .font(.system(size: 14))
                .foregroundStyle(item.isDir ? RMTheme.accent : RMTheme.textSub)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundStyle(RMTheme.text)
                    .lineLimit(1)
                Text(item.isDir ? "文件夹 · \(TimeFmt.string(from: item.modified))" : "\(item.size) 字节 · \(TimeFmt.string(from: item.modified))")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(picked ? RMTheme.surface : RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isDir {
                fs.enter(item.name)
                selected.removeAll()
            } else if multiMode {
                // 多选：点文件只勾选，不弹详情页
                if picked { selected.remove(item.name) } else { selected.insert(item.name) }
            } else {
                detail = item
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("复制") { fs.putClipboard(cut: false, name: item.name) }
                .tint(RMTheme.accent)
            Button("剪切") { fs.putClipboard(cut: true, name: item.name) }
                .tint(RMTheme.warn)
            Button("删除", role: .destructive) {
                fs.remove(name: item.name)
                selected.remove(item.name)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // 目录也能改：先改名成 "名字 2"，再走详情页重命名
            Button("复制一份") { fs.copy(name: item.name, toDir: fs.path) }
                .tint(RMTheme.accent)
            Button("重命名") {
                fs.rename(from: item.name, to: item.name + " 2")
            }
            .tint(RMTheme.warn)
        }
    }

}

// MARK: - 文件详情（文本 / Hex / 属性 / 操作）

struct FileDetailView: View {
    @EnvironmentObject private var fs: FileStore
    @Environment(\.dismiss) private var dismiss
    let item: RMFileEntry

    @State private var text: String = ""
    @State private var canEdit = false
    @State private var hexText: String = ""
    @State private var hexTotal = 0
    @State private var hexFrom = 0
    @State private var hexLoaded = 0
    @State private var hexLoading = false
    @State private var hexWrite = ""
    @State private var hexOffset = "0"
    @State private var rename = ""
    @State private var tab = 0

    /// 文件夹没有"文本/Hex"，只有一个目录操作页
    private var isDir: Bool { item.isDir }

    var body: some View {
        NavigationStack {
            Form {
                if isDir { dirSections } else { fileSections }
            }
            .background(RMTheme.bg)
            .navigationTitle(item.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                rename = item.name
                if !isDir {
                    if let t = fs.readText(name: item.name) { text = t; canEdit = true }
                    loadMoreHex(from: 0)
                }
            }
        }
    }

    // MARK: - 文件夹改动（重命名 / 在里面新建 / 压缩 / 删除 / 属性）

    @ViewBuilder
    private var dirSections: some View {
        Section("目录操作") {
            HStack {
                Text("重命名成")
                Spacer()
                TextField("", text: $rename)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 150)
            }
            Button("重命名这个文件夹") {
                fs.rename(from: item.name, to: rename.isEmpty ? item.name : rename)
            }
        }
        Section("在里面建") {
            Button("新建一个文件") { fs.writeFileIn(dir: item.name, name: "新文件.txt") }
            Button("新建一个文件夹") { fs.makeDirIn(dir: item.name, name: "新文件夹") }
        }
        Section("打包 / 删除") {
            Button("压缩成 zip") { fs.zip(name: item.name) }
            Button("解压缩") { fs.unzip(name: item.name) }
            Button("剪切这个文件夹") { fs.putClipboard(cut: true, name: item.name) }
            Button("复制这个文件夹") { fs.putClipboard(cut: false, name: item.name) }
            Button("删除", role: .destructive) { fs.remove(name: item.name); dismiss() }
        }
        Section("属性") {
            ForEach(Array(fs.attributes(name: item.name).enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0).font(.system(size: 12)).foregroundStyle(RMTheme.textSub)
                    Spacer()
                    Text(pair.1).font(.system(size: 12)).foregroundStyle(RMTheme.text)
                }
            }
        }
    }

    // MARK: - 文件（文本 / Hex / 属性 / 管理）

    @ViewBuilder
    private var fileSections: some View {
        Section("操作") {
            Picker("", selection: $tab) {
                Text("文本").tag(0)
                Text("Hex").tag(1)
                Text("属性").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowBackground(RMTheme.panel)
        }

        if tab == 0 {
                    Section {
                        if canEdit {
                            TextEditor(text: $text)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 220)
                                .autocorrectionDisabled()
                                .autocapitalization(.none)
                        } else {
                            Text(canEdit ? "" : "这个文件内容不是 UTF-8 文本，去 Hex 页改。")
                                .font(.system(size: 12))
                                .foregroundStyle(RMTheme.textSub)
                        }
                    }
                    Section {
                        Button("保存文本") {
                            fs.writeText(name: item.name, text: text)
                        }
                        .foregroundStyle(RMTheme.accent)
                    }
                } else if tab == 1 {
                    Section {
                        HStack(spacing: 8) {
                            Text("共 \(hexTotal) 字节 · 已载入 \(hexLoaded)")
                                .font(.system(size: 11))
                                .foregroundStyle(RMTheme.textSub)
                            Spacer()
                            Button(hexLoading ? "加载中…" : "再往下 4 KB") {
                                loadMoreHex()
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(RMTheme.accent)
                            .disabled(hexLoading || hexFrom >= hexTotal)
                        }
                        // 文本框动态加载，一次不把整个文件塞进内存/视图
                        TextEditor(text: .constant(hexText))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 200, maxHeight: 360)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                            .disabled(true)
                            .listRowBackground(RMTheme.bg)
                    }
                    Section("从偏移写字节（只改这一段，其它字节不动）") {
                        HStack {
                            Text("偏移")
                            TextField("0", text: $hexOffset)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                        }
                        TextField("字节（16 进制，空格分隔，如 48 65 6C 6C 6F）", text: $hexWrite)
                            .font(.system(size: 12, design: .monospaced))
                            .autocapitalization(.none)
                        Button("写入") {
                            var bytes = [UInt8]()
                            for tok in hexWrite.split(separator: " ") {
                                if let b = UInt8(tok.trimmingCharacters(in: .punctuationCharacters), radix: 16) { bytes.append(b) }
                            }
                            guard !bytes.isEmpty, let off = Int(hexOffset.trimmingCharacters(in: .whitespaces)) else {
                                fs.message = "偏移或字节没填对"
                                return
                            }
                            _ = fs.writeBytes(name: item.name, offset: off, bytes: bytes)
                            fs.message = fs.message
                            loadMoreHex(from: 0)
                        }
                        .foregroundStyle(RMTheme.accent)
                    }
                    Section("整段替换（文本框里粘一整段 hex）") {
                        Button("用当前这段 hex 覆盖整个文件") {
                            _ = fs.writeHexText(name: item.name, hexText: hexText)
                            loadMoreHex(from: 0)
                        }
                        .foregroundStyle(RMTheme.warn)
                    }
                } else {
                    Section("属性") {
                        ForEach(Array(fs.attributes(name: item.name).enumerated()), id: \.offset) { _, pair in
                            let k = pair.0
                            let v = pair.1
                            HStack {
                                Text(k).font(.system(size: 12)).foregroundStyle(RMTheme.textSub)
                                Spacer()
                                Text(v).font(.system(size: 12)).foregroundStyle(RMTheme.text)
                            }
                        }
                    }
                }

                Section("管理") {
                    HStack {
                        Text("重命名成")
                        Spacer()
                        TextField("", text: $rename)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 150)
                    }
                    Button("重命名") {
                        fs.rename(from: item.name, to: rename.isEmpty ? item.name : rename)
                    }
                    Button("压缩成 zip") { fs.zip(name: item.name) }
                    Button("解压缩") { fs.unzip(name: item.name) }
                    Button("剪切") { fs.putClipboard(cut: true, name: item.name) }
                    Button("复制") { fs.putClipboard(cut: false, name: item.name) }
                    Button("粘贴到当前目录") { fs.paste() }
                    Button("删除", role: .destructive) { fs.remove(name: item.name); dismiss() }
                }
            }
        }
    }

    /// 分页载入 hex（一次 4 KB，点"再往下"接着来），避免一次性把大文件全灌进视图
    private func loadMoreHex(from: Int? = nil) {
        if let from { hexFrom = from }
        guard !hexLoading else { return }
        hexLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = fs.hexText(name: item.name, from: hexFrom, count: 4096)
            DispatchQueue.main.async {
                self.hexText = r.text
                self.hexTotal = r.total
                self.hexLoaded = hexFrom + r.loaded
                self.hexLoading = false
                if r.loaded == 0 { self.hexFrom = self.hexTotal } else { self.hexFrom += r.loaded }
            }
        }
    }
}

// MARK: - 终端（JS 环境 + 常用文件命令）

struct TerminalView: View {
    @EnvironmentObject private var fs: FileStore
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = ["RyMind 终端 · 工作空间是 /rmind", "输入 help 看命令，js <文件> 跑 JS"]
    @State private var cmd = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { l in
                            Text(l).font(.system(size: 12, design: .monospaced)).foregroundStyle(RMTheme.text)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(hex: 0x0E0E10))

                HStack {
                    TextField("命令", text: $cmd)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(RMTheme.text)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit { run() }
                    Button("执行") { run() }
                        .font(.system(size: 12))
                        .foregroundStyle(RMTheme.accent)
                }
                .padding(10)
                .background(RMTheme.rail)
            }
            .navigationTitle("终端 · \(fs.displayPath)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func run() {
        let raw = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        lines.append("$ \(raw)")
        let parts = raw.split(separator: " ")
        let a0 = String(parts[0]).lowercased()
        let a1 = parts.count > 1 ? String(parts[1]) : ""
        let a2 = parts.count > 2 ? String(parts[2]) : ""

        switch a0 {
        case "help":
            lines.append("ls 列目录 · cd <目录> · pwd 当前路径 · cat <文件> · echo <文本> · mkdir <名> · touch <名> · rm <名> · mv <源> <目标> · cp <源> <目标> · head -n <文件> · wc <文件> · write <名> <内容> · js <脚本> · clear")
        case "clear":
            lines.removeAll()
        case "ls":
            fs.refresh()
            if fs.entries.isEmpty { lines.append("（空）") }
            for e in fs.entries { lines.append("\(e.isDir ? "d" : "-") \(e.isDir ? "  <目录>  " : String(format: "%8d", e.size))  \(e.name)") }
        case "pwd":
            lines.append(fs.displayPath)
        case "cd":
            if a1 == ".." { fs.up() } else if a1.isEmpty { fs.path = "/"; fs.refresh() }
            else if fs.entries.contains(where: { $0.name == a1 && $0.isDir }) { fs.enter(a1) }
            else { lines.append("cd: \(a1): 没有这个目录") }
        case "cat":
            if let t = fs.readText(name: a1) { lines.append(t) } else { lines.append("cat: \(a1): 打不开") }
        case "echo":
            lines.append(parts.dropFirst().joined(separator: " "))
        case "mkdir":
            fs.makeDir(a1); lines.append("mkdir \(a1)")
        case "touch":
            if let d = fs.readData(name: a1) { _ = d } // 已存在
            fs.writeData(name: a1, data: Data())
        case "rm":
            fs.remove(name: a1); lines.append("rm \(a1)")
        case "mv":
            fs.rename(from: a1, to: a2); lines.append("mv \(a1) -> \(a2)")
        case "cp":
            fs.copy(name: a1, toDir: fs.path); lines.append("cp \(a1)")
        case "head":
            if let t = fs.readText(name: a1) {
                lines.append(t.prefix(10).split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n"))
            }
        case "wc":
            if let t = fs.readText(name: a1) {
                lines.append("\(t.count) 字符 · \(t.components(separatedBy: "\n").count) 行")
            }
        case "write":
            fs.writeText(name: a1, text: parts.dropFirst(2).joined(separator: " "))
            lines.append("已写入 \(a1)")
        case "js":
            if let t = fs.readText(name: a1) { runJS(t) }
            else { lines.append("js: \(a1) 不是能读的文本") }
        default:
            lines.append("\(a0): 不认识。输入 help")
        }
        cmd = ""
    }

    private func runJS(_ source: String) {
        guard let ctx = JSContext() else { lines.append("JSContext 不可用"); return }
        var out: [String] = []
        // JSContext 的 key 必须是 NSCopying 对象，不能直接传 String
        ctx.setObject({ (s: Any) -> Void in out.append(String(describing: s)) },
                      forKeyedSubscript: NSString(string: "emitCb"))
        ctx.setObject({ (p: String) -> [String] in self.fs.entries.map { $0.name } },
                      forKeyedSubscript: NSString(string: "hostList"))
        ctx.setObject({ (p: String) -> String in self.fs.readText(name: p) ?? "" },
                      forKeyedSubscript: NSString(string: "hostRead"))
        ctx.setObject({ (p: String, s: String) -> Bool in self.fs.writeText(name: p, text: s); return true },
                      forKeyedSubscript: NSString(string: "hostWrite"))
        ctx.evaluateScript("""
        var console = { log: function(){ emitCb(Array.prototype.slice.call(arguments).join(' ')); } };
        function print(s){ emitCb(String(s)); }
        function list(p){ try { return hostList(p || '.'); } catch(e){ return []; } }
        function read(p){ return hostRead(p); }
        function write(p, s){ return hostWrite(p, String(s)); }
        """)
        ctx.exceptionHandler = { _, ex in
            if let e = ex?.toString() { out.append("js error: " + e) }
        }
        ctx.evaluateScript(source)
        lines.append(contentsOf: out.isEmpty ? ["（脚本没有输出）"] : out)
    }
}

// MARK: - 小组件：提示条

private extension View {
    func toast(_ message: String) -> some View {
        overlay(alignment: .bottom) {
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RMTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }
}
