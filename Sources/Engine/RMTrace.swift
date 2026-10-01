import Foundation
import UIKit

/// RyMind 诊断日志：内存环形缓冲 + 落盘到文件库，外加崩溃捕获。
/// ⚠️ 纪律：后台线程**绝不**直接写 @Published —— log() 一律丢进串行走，回主线程再播。
final class RMTrace: ObservableObject {

    static let shared = RMTrace()

    struct Entry: Identifiable {
        let id = UUID()
        let ts: Date
        let tag: String
        let text: String
        var time: String {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "zh_CN")
            return f.string(from: ts)
        }
        var body: String { "[\(time)] [\(tag)] \(text)" }
    }

    @Published private(set) var entries: [Entry] = []

    private let serial = DispatchQueue(label: "rmind.trace.serial")
    private let cap = 160
    private let fileURL: URL? = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("rmind-diag.log")
    }()

    private init() {}

    func log(_ text: String, tag: String = "info") {
        serial.async {
            let e = Entry(ts: Date(), tag: tag, text: text)
            DispatchQueue.main.async {
                var next = self.entries; next.append(e)
                if next.count > self.cap { next.removeFirst(next.count - self.cap) }
                self.entries = next
            }
            self.appendFile("[\(ISO())] [\(tag)] \(text)\n")
        }
    }

    private func ISO() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: Date())
    }

    private func appendFile(_ s: String) {
        guard let url = fileURL else { return }
        serial.async {
            guard let data = s.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func exportText() -> String {
        serial.sync { self.entries.map { $0.body }.joined(separator: "\n") }
    }

    func clear() {
        serial.async {
            DispatchQueue.main.async { self.entries = [] }
            if let url = self.fileURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 装崩溃捕获：NSException + 三个会杀死 App 的信号。写进同一份日志，
    /// 这样「生图点一下就崩」我能直接看到崩在哪个调用栈附近。
    func installHandlers() {
        serial.async {
            NSSetUncaughtExceptionHandler { ex, _ in
                RMTrace.shared.log("CRASH exception: \(ex)", tag: "crash")
                let r = ex.reason ?? ""
                if !r.isEmpty { RMTrace.shared.log("CRASH reason: \(r)", tag: "crash") }
                let stack = ex.callStackSymbols.prefix(12).joined(separator: "\n")
                RMTrace.shared.log("CRASH stack:\n\(stack)", tag: "crash")
            }
            var sigs = [Int32(SIGABRT), Int32(SIGSEGV), Int32(SIGBUS)]
            sigs.forEach { sig in
                signal(sig) { s in
                    RMTrace.shared.log("CRASH signal=\(s)", tag: "crash")
                    let names = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
                    RMTrace.shared.log("CRASH stack:\n\(names)", tag: "crash")
                    exit(s)
                }
            }
        }
    }
}
