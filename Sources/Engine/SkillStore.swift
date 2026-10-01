import Foundation
import SwiftUI

struct RMSkill: Identifiable, Codable {
    var id: String
    var name: String
    var enabled: Bool
    var addedAt: Date
    var fileCount: Int
    var hasEntry: Bool          // 包里有没有 SKILL.md / skill.md

    var desc: String {
        let d = "\(fileCount) 个文件"
        return hasEntry ? "\(d) · 含 SKILL.md" : d
    }
}

/// Skill 库：上传 zip → 自动解压 → 可管理 → 对话里能附加
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    @Published var skills: [RMSkill] = []

    private let fm = FileManager.default
    private let jsonName = "skills.json"

    private init() { load() }

    var rootURL: URL { docs().appendingPathComponent("Skills") }
    var indexURL: URL { docs().appendingPathComponent(jsonName) }

    func docs() -> URL {
        let d = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        return URL(fileURLWithPath: d)
    }

    func dirURL(for skill: RMSkill) -> URL { rootURL.appendingPathComponent(skill.id) }

    /// 拿到 Skill 里某个可执行脚本（SKILL.md 里写的 scripts/xxx.js）
    func scriptURL(for skill: RMSkill, named name: String) -> URL? {
        let c = dirURL(for: skill).appendingPathComponent("scripts").appendingPathComponent(name)
        if fm.fileExists(atPath: c.path) { return c }
        let alt = dirURL(for: skill).appendingPathComponent(name)
        return fm.fileExists(atPath: alt.path) ? alt : nil
    }

    func entryURL(for skill: RMSkill) -> URL? {
        for n in ["SKILL.md", "skill.md", "SKILL.MD"] {
            let u = dirURL(for: skill).appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 上传 Skill.zip：拷进来 → 解压 → 进索引
    @discardableResult
    func importSkill(from src: URL) -> String {
        let id = "skill-" + UUID().uuidString.prefix(8).lowercased()
        let zipURL = rootURL.appendingPathComponent(id + ".zip")
        let outURL = rootURL.appendingPathComponent(id)
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? fm.removeItem(at: outURL)

        do {
            try fm.copyItem(at: src, to: zipURL)     // asCopy 已经复制过，move 更快但可能失败
        } catch {
            try? fm.copyItem(at: src, to: zipURL)
        }
        _ = try? RMZip.extract(at: zipURL, to: outURL)

        let files = (try? fm.subpaths(atPath: outURL.path)) ?? []
        let hasEntry = entryURL(for: RMSkill(id: id, name: id, enabled: true, addedAt: Date(), fileCount: files.count, hasEntry: false)) != nil
        var name = id
        if let e = entryURL(for: RMSkill(id: id, name: id, enabled: true, addedAt: Date(), fileCount: 0, hasEntry: false)),
           let md = try? String(contentsOf: e, encoding: .utf8) {
            for line in md.split(separator: "\n") {
                if line.hasPrefix("#") {
                    name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        if name.isEmpty || name.hasPrefix("skill-") { name = src.lastPathComponent.replacingOccurrences(of: ".zip", with: "") }

        let sk = RMSkill(id: id, name: name, enabled: true, addedAt: Date(), fileCount: files.count, hasEntry: hasEntry)
        skills.insert(sk, at: 0)
        save()
        return "\(name) · \(files.count) 个文件"
    }

    func toggle(_ id: String) {
        guard let i = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[i].enabled.toggle()
        save()
    }

    func remove(_ id: String) {
        if let s = skills.first(where: { $0.id == id }) {
            try? fm.removeItem(at: dirURL(for: s))
            let z = rootURL.appendingPathComponent(s.id + ".zip")
            try? fm.removeItem(at: z)
        }
        skills.removeAll { $0.id == id }
        save()
    }

    var enabledSkills: [RMSkill] { skills.filter { $0.enabled } }

    private func save() {
        guard let d = try? JSONEncoder().encode(skills) else { return }
        try? d.write(to: indexURL)
    }

    private func load() {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([RMSkill].self, from: d) else { return }
        skills = list
    }
}
