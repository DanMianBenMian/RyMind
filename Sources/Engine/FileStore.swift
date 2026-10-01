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

    func up() {
        if path == "/" { return }
        let p = (path as NSString).deletingLastPathComponent
        path = p == "/" ? "/" : p
        refresh()
    }

    // MARK: - 基本操作

    func makeDir(_ name: String) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        try? fm.createDirectory(at: url(for: path).appendingPathComponent(n), withIntermediateDirectories: true)
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
        out.append(("路径", displayPath.replacingOccurrences(of: name, with: "") + name))
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

    func writeData(name: String, data: Data) {
        let n = clean(name)
        guard !n.isEmpty else { return }
        let target = url(for: path).appendingPathComponent(n)
        try? fm.createDirectory(atPath: target.deletingLastPathComponent().path, withIntermediateDirectories: true)
        try? data.write(to: target)
        message = "已写入 \(n)"
        refresh()
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
