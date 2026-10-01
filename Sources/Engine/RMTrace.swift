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
        var time: String { RMTrace.hh(ts) }
        var body: String { "[\(time)] [\(tag)] \(text)" }
    }

    /// ⚠️ NSDateFormatter 底下是 ICU，每次 new 一个要重新 construct SimpleDateFormat（很贵）。
    /// 出图循环里打点一多就会明显拖慢，所以整份 App 只养两个 formatter 常驻。
    private static let fmtLock = NSLock()
    private static var _hh: DateFormatter?
    private static var _iso: DateFormatter?
    private static func hh(_ d: Date) -> String {
        fmtLock.lock(); defer { fmtLock.unlock() }
        if _hh == nil {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "zh_CN")
            _hh = f
        }
        return _hh!.string(from: d)
    }
    private static func iso() -> String {
        fmtLock.lock(); defer { fmtLock.unlock() }
        if _iso == nil {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "zh_CN")
            _iso = f
        }
        return _iso!.string(from: Date())
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
            let stamp = self.ISO()
            self.appendFile("[\(stamp)] [\(tag)] \(text)\n")
        }
    }

    private func ISO() -> String { RMTrace.iso() }

    /// 崩溃线程上**同步**写一行 —— 信号处理器里调 log() 是 async，来不及落盘进程就没了，
    /// 所以这里必须直接 write，再 exit。
    private func writeNow(_ tag: String, _ text: String) {
        guard let url = fileURL,
              let data = ("[\(RMTrace.iso())] [\(tag)] \(text)\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
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
            NSSetUncaughtExceptionHandler { ex in
                let stack = ex.callStackSymbols.prefix(12).joined(separator: "\n")
                RMTrace.shared.writeNow("CRASH", "NSException \(ex)\nreason: \(ex.reason ?? "")\n\(stack)")
                RMTrace.shared.log("CRASH exception: \(ex)", tag: "crash")
                exit(0)
            }
            // ⚠️ SIGTRAP 必须接：Swift 的 trap（类型越界 / fatalError / 溢出）走的就是 EXC_BREAKPOINT = SIGTRAP。
            var sigs = [Int32(SIGABRT), Int32(SIGSEGV), Int32(SIGBUS), Int32(SIGTRAP)]
            sigs.forEach { sig in
                signal(sig) { s in
                    let names = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
                    RMTrace.shared.writeNow("CRASH", "signal=\(s)\n\(names)")
                    RMTrace.shared.log("CRASH signal=\(s)", tag: "crash")
                    exit(0)
                }
            }
        }
    }
}
