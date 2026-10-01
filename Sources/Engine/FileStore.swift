import Foundation
import SwiftUI

struct RMFileEntry: Identifiable {
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Date
    var id: String { name }
}

/// 文件资源库：unix 风格路径 + 每个对话独立工作空间
final class FileStore: ObservableObject {
    static let shared = FileStore()

    @Published var entries: [RMFileEntry] = []
    @Published var path: String = "/"
    @Published var message: String = ""

    private struct ClipItem { let cut: Bool; let from: String }   // from = unix 完整路径
    private static var clip: ClipItem?

    private let fm = FileManager.default

    var rootURL: URL { docs().appendingPathComponent("Workspaces") }

    func docs() -> URL {
        let d = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        return URL(fileURLWithPath: d)
    }

    func url(for p: String) -> URL {
        let clean = p.hasPrefix("/") ? String(p.dropFirst()) : p
        return clean.isEmpty ? rootURL : rootURL.appendingPathComponent(clean)
    }

    /// 对外展示的 unix 路径（根是 /rmind）
    var displayPath: String {
        let p = path.isEmpty || path == "/" ? "" : path
        return "/rmind" + (p.hasPrefix("/") ? p : p)
    }

    // MARK: - 列表

    func refresh() {
        let u = url(for: path)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: u.path) else { entries = []; return }
        var list: [RMFileEntry] = []
        for n in names {
            let f = u.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: f.path, isDirectory: &isDir) else { continue }
            var mod = Date()
            if let at = try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date { mod = at }
            let size: Int64 = isDir.boolValue ? 0 : ((try? fm.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0)
            list.append(RMFileEntry(name: n, isDir: isDir.boolValue, size: size, modified: mod))
        }
        list.sort { lhs, rhs in
            if lhs.isDir != rhs.isDir { return lhs.isDir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        entries = list
    }

    func enter(_ name: String) {
        path = (path == "/" ? "" : path) + "/" + name
        refresh()
    }

    /// 上一级（一次只退一层）
    func up() {
        if path == "/" { return }
        let p = (path as NSString).deletingLastPathComponent
        path = p == "/" ? "/" : p
        refresh()
    }

    /// 直接回根目录
    func goRoot() {
        path = "/"
        refresh()
    }

    /// 往下钻（path 可以是 "/chat-abcd" 这种完整路径）
    func enterPath(_ p: String) {
        let clean = p.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        path = clean.hasPrefix("/") ? clean : "/" + clean
        refresh()
    }

    /// Workspaces 下所有子目录的 unix 路径（移动/复制的目标列表）
    var dirTreePaths: [String] {
        var out: [String] = []
        collectDirs(at: rootURL, into: &out)
        return out.sorted()
    }

    private func collectDirs(at dir: URL, into out: inout [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names {
            let f = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let rel = f.path.replacingOccurrences(of: rootURL.path, with: "")
            out.append(rel.isEmpty ? "/" : rel)
            collectDirs(at: f, into: &out)
        }
    }

    // MARK: - 基本操作

    func makeDir(_ name: String) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        try? fm.createDirectory(at: url(for: path).appendingPathComponent(n), withIntermediateDirectories: true)
        refresh()
    }

    /// 在当前目录的某个子目录里建文件夹（⚠️ 别用 makeDir：它会 lastPathComponent 把路径吃掉）
    func makeDirIn(dir: String, name: String) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        let target = url(for: path).appendingPathComponent(dir).appendingPathComponent(n)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        refresh()
    }

    /// 在当前目录的某个子目录里写文件（新建文件用，建完点开就能写）
    func writeFileIn(dir: String, name: String, text: String = "") {
        let n = clean(name)
        guard !n.isEmpty else { return }
        let target = url(for: path).appendingPathComponent(dir).appendingPathComponent(n)
        try? text.write(to: target, atomically: true, encoding: .utf8)
        message = "已在 \(dir) 建了 \(n)"
        refresh()
    }

    func upload(from src: URL, nameHint: String? = nil) {
        _ = src.startAccessingSecurityScopedResource()
        let data = (try? Data(contentsOf: src)) ?? Data()
        src.stopAccessingSecurityScopedResource()
        guard !data.isEmpty else { message = "读取文件失败"; return }
        let name = clean(nameHint ?? src.lastPathComponent)
        guard !name.isEmpty else { return }
        do {
            try data.write(to: url(for: path).appendingPathComponent(name))
            message = "已加入 \(name)"
        } catch { message = "写入失败：\(error.localizedDescription)" }
        refresh()
    }

    func remove(name: String) {
        try? fm.removeItem(at: url(for: path).appendingPathComponent(name))
        refresh()
    }

    /// 批量删除（多选用）：一次只删当前目录下的这些名字，删完统一刷一次列表
    func remove(names: [String]) {
        let set = Set(names)
        for n in set {
            try? fm.removeItem(at: url(for: path).appendingPathComponent(n))
        }
        refresh()
    }

    /// 当前目录下这些名字的文件总字节（聊天里显示附件大小用）
    func size(of name: String) -> Int64 {
        (((try? fm.attributesOfItem(atPath: url(for: path).appendingPathComponent(name).path)[.size]) as? NSNumber)?.int64Value) ?? 0
    }

    func rename(from: String, to: String) {
        let n = clean(to)
        guard !n.isEmpty else { return }
        let old = url(for: path).appendingPathComponent(from)
        let new = url(for: path).appendingPathComponent(n)
        if fm.fileExists(atPath: new.path) { message = "同名文件已存在"; return }
        try? fm.moveItem(at: old, to: new)
        refresh()
    }

    func move(name: String, toDir: String) {
        let src = url(for: path).appendingPathComponent(name)
        let dst = url(for: toDir).appendingPathComponent(name)
        try? fm.moveItem(at: src, to: dst)
        refresh()
    }

    func copy(name: String, toDir: String) {
        let src = url(for: path).appendingPathComponent(name)
        let dst = url(for: toDir).appendingPathComponent(name)
        try? fm.copyItem(at: src, to: dst)
        refresh()
    }

    // 剪切板：复制 / 剪切
    func putClipboard(cut: Bool, name: String) {
        let full = path + "/" + name
        FileStore.clip = ClipItem(cut: cut, from: full)
        message = cut ? "已剪切 \(name)" : "已复制 \(name)"
    }

    func paste() {
        guard let c = FileStore.clip else { message = "剪贴板是空的"; return }
        let name = (c.from as NSString).lastPathComponent
        let srcFull = c.from
        // 复制到当前目录；如果在根目录，就放回它原来的位置
        let toDir: String = path == "/" && !(srcFull as NSString).deletingLastPathComponent.hasPrefix("chat-") ? (srcFull as NSString).deletingLastPathComponent : path
        if c.cut {
            let src = url(for: srcFull)
            let dst = url(for: toDir).appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { message = "同名文件已存在"; FileStore.clip = nil; return }
            try? fm.moveItem(at: src, to: dst)
        } else {
            try? fm.copyItem(at: url(for: srcFull), to: url(for: toDir).appendingPathComponent(name))
        }
        FileStore.clip = nil
        message = "已粘贴 \(name)"
        refresh()
    }

    var hasClipboard: Bool { FileStore.clip != nil }

    // MARK: - 内容读写

    func attributes(name: String) -> [(String, String)] {
        let f = url(for: path).appendingPathComponent(name)
        guard let at = try? fm.attributesOfItem(atPath: f.path) else { return [] }
        let size = at[.size] as? NSNumber
        let created = at[.creationDate] as? Date ?? Date()
        let modified = at[.modificationDate] as? Date ?? Date()
        let isDir = (try? fm.attributesOfItem(atPath: f.path)[.type] as? FileAttributeType) == .typeDirectory

        var out: [(String, String)] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // 路径要拼对：根目录是 /rmind/xxx，子目录是 /rmind/父/xxx
        let basePath = (path == "/" ? "" : path)
        out.append(("路径", "/rmind\(basePath)/\(name)"))
        out.append(("大小", isDir ? "目录" : formatSize(size?.int64Value ?? 0)))
        out.append(("类型", isDir ? "文件夹" : (name.components(separatedBy: ".").last ?? "文件").uppercased()))
        out.append(("创建时间", fmt.string(from: created)))
        out.append(("修改时间", fmt.string(from: modified)))
        return out
    }

    func readText(name: String) -> String? {
        let f = url(for: path).appendingPathComponent(name)
        return try? String(contentsOf: f, encoding: .utf8)
    }

    func writeText(name: String, text: String) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        let f = url(for: path).appendingPathComponent(n)
        try? text.write(to: f, atomically: true, encoding: .utf8)
        message = "已保存 \(n)"
        refresh()
    }

    func readData(name: String) -> Data? {
        try? Data(contentsOf: url(for: path).appendingPathComponent(name))
    }

    /// 按 unix 绝对路径读内容（对话页从文件库选文件后用，不受当前 path 影响）
    func readAt(_ unixPath: String) -> Data? {
        try? Data(contentsOf: url(for: unixPath))
    }

    /// 在某个 unix 目录下建一个空文件（文件页「新建文件」用）
    func createFile(at unixPath: String, name: String, text: String = "") {
        let n = clean(name)
        guard !n.isEmpty else { return }
        try? fm.createDirectory(at: url(for: unixPath), withIntermediateDirectories: true)
        let f = url(for: unixPath).appendingPathComponent(n)
        guard !fm.fileExists(atPath: f.path) else { message = "\(n) 已存在"; return }
        try? text.write(to: f, atomically: true, encoding: .utf8)
        message = "已新建 \(n)"
    }

    func writeData(name: String, data: Data) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        let target = url(for: path).appendingPathComponent(n)
        try? fm.createDirectory(atPath: target.deletingLastPathComponent().path, withIntermediateDirectories: true)
        try? data.write(to: target)
        message = "已写入 \(n)"
        refresh()
    }

    /// 从某个偏移开始写字节（只覆盖这一段，其它字节原样留着）
    /// - offset: 字节偏移，超出文件长度就补 0 撑到那个位置
    func writeBytes(name: String, offset: Int, bytes: [UInt8]) -> Bool {
        let n = clean(name)
        guard !n.isEmpty, !bytes.isEmpty, offset >= 0 else { return false }
        let f = url(for: path).appendingPathComponent(n)
        var data = (try? Data(contentsOf: f)) ?? Data()
        if offset + bytes.count > data.count {
            data.append(Data(count: offset + bytes.count - data.count))
        }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        do {
            try data.write(to: f)
            message = "已从偏移 \(offset) 写入 \(bytes.count) 字节"
            refresh()
            return true
        } catch {
            message = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Hex 文本整体替换（文本框里粘一整段 hex 用）
    func writeHexText(name: String, hexText: String) -> Bool {
        let n = clean(name)
        guard !n.isEmpty else { return false }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexText.count / 3)
        var pending = ""
        for ch in hexText {
            if ch == " " || ch == "\n" || ch == "\t" || ch == "," { continue }
            pending.append(ch)
            if pending.count == 2 {
                if let b = UInt8(pending, radix: 16) { bytes.append(b) }
                pending = ""
            }
        }
        guard !bytes.isEmpty else { message = "没解析出字节"; return false }
        let f = url(for: path).appendingPathComponent(n)
        do {
            try Data(bytes).write(to: f)
            message = "已用 \(bytes.count) 字节替换 \(n)"
            refresh()
            return true
        } catch {
            message = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 把二进制读成 hex 文本（每行 16 字节，带偏移和 ASCII 栏）
    func hexText(name: String, from: Int = 0, count: Int = 4096) -> (text: String, total: Int, loaded: Int) {
        guard let d = readData(name: name) else { return ("", 0, 0) }
        let total = d.count
        let start = max(0, min(from, total))
        let n = max(0, min(count, total - start))
        if n == 0 { return ("（空文件）", total, 0) }
        var s = ""
        s.reserveCapacity(n * 4)
        var i = start
        while i < start + n {
            let end = min(i + 16, start + n)
            var hex = ""
            var ascii = ""
            hex.reserveCapacity(48)
            ascii.reserveCapacity(17)
            for j in i..<end {
                let c = d[j]
                hex += String(format: "%02X ", c)
                ascii += (c >= 32 && c < 127) ? String(UnicodeScalar(c)) : "."
            }
            s += String(format: "%08X  %@  |%@|\n", i, hex, ascii)
            i = end
        }
        return (s, total, n)
    }

    // MARK: - 打包

    func zip(name: String) {
        let item = url(for: path).appendingPathComponent(name)
        let out = url(for: path).appendingPathComponent(name + ".zip")
        if (try? RMZip.archive(roots: [item], to: out)) != nil {
            message = "已打包 \(name).zip"
        } else {
            message = "打包失败"
        }
        refresh()
    }

    func unzip(name: String) {
        let z = url(for: path).appendingPathComponent(name)
        let dest = url(for: path).appendingPathComponent((name as NSString).deletingPathExtension)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let ok = (try? RMZip.extract(at: z, to: dest)) != nil
        message = ok ? "已解出 \(dest.lastPathComponent)" : "解压失败（可能不是 zip）"
        refresh()
    }

    /// 某个对话的工作空间（unix 路径）
    func workspacePath(for sessionID: UUID) -> String {
        let short = String(sessionID.uuidString.prefix(4))
        let p = "/chat-\(short)"
        try? fm.createDirectory(at: url(for: p), withIntermediateDirectories: true)
        return p
    }

    // MARK: - 小工具

    private func clean(_ s: String) -> String {
        let base = (s as NSString).lastPathComponent
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatSize(_ b: Int64) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / 1048576) }
        return String(format: "%.2f GB", Double(b) / 1073741824)
    }
}
