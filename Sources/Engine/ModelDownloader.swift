import Foundation

/// 模型下载器：后台 URLSession（App 划后台也能继续下），带进度、暂停/续传、失败自动切镜像源。
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published var progress: [String: Double] = [:]
    @Published var downloadingIds: Set<String> = []
    @Published var lastMessage: String = ""

    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resumeData: [String: Data] = [:]
    private var triedMirror: Set<String> = []
    /// 每个下载上一次上报的进度（值, 时间）—— 用来节流
    private var lastReported: [String: (Double, Date)] = [:]
    private var lastMsgAt: Date = Date(timeIntervalSince1970: 0)

    /// 进度/文案统一走节流：URLSession 的 didWriteData 一次大文件能打几百次，
    /// 每次都 @Published 会让整个列表重绘 —— 进度条一闪一闪、滑动都卡就是这么来的。
    private func setMessage(_ s: String) {
        let now = Date()
        guard now.timeIntervalSince(lastMsgAt) >= 0.3 else { return }
        lastMsgAt = now
        let text = s
        DispatchQueue.main.async { self.lastMessage = text }
    }

    /// 后台下载全部结束时的系统回调（AppDelegate 里存进来）
    var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.research.rymind.download")
        cfg.isDiscretionary = false          // 不要系统"择机"下载，尽量立刻跑
        cfg.sessionSendsLaunchEvents = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: - 控制

    func start(_ m: RMModel) {
        guard tasks[m.id] == nil else { return }
        let urlString = triedMirror.contains(m.id) ? m.mirrorURL : (m.primaryURL ?? m.mirrorURL)
        guard !urlString.isEmpty, let u = URL(string: urlString) else {
            setMessage("\(m.name) 暂无可用下载源")
            return
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 60
        let t = session.downloadTask(with: req)
        t.taskDescription = m.id
        tasks[m.id] = t
        lastReported[m.id] = (0, Date())
        DispatchQueue.main.async {
            self.downloadingIds.insert(m.id)
            self.progress[m.id] = 0
        }
        setMessage("开始下载 \(m.name)")
        t.resume()
    }

    func pause(_ id: String) {
        guard let t = tasks[id] else { return }
        t.cancel { [weak self] data in
            guard let self = self else { return }
            self.resumeData[id] = data
            self.lastReported.removeValue(forKey: id)
            DispatchQueue.main.async { self.downloadingIds.remove(id) }
        }
        tasks[id] = nil
        lastReported.removeValue(forKey: id)
    }

    func resume(_ id: String) {
        if let data = resumeData[id] {
            let t = session.downloadTask(withResumeData: data)
            t.taskDescription = id
            tasks[id] = t
            DispatchQueue.main.async { self.downloadingIds.insert(id) }
            t.resume()
        } else if let m = ModelStore.shared.model(id: id) {
            start(m)
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        resumeData[id] = nil
        triedMirror.remove(id)
        lastReported.removeValue(forKey: id)
        DispatchQueue.main.async {
            self.downloadingIds.remove(id)
            self.progress[id] = nil
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let now = Date()
        if let prev = lastReported[id] {
            // 跨过 0.5% 才报，或者 0.8 秒才报一次（既跟得上，又不刷爆主线程）
            guard (p - prev.0) >= 0.005 || now.timeIntervalSince(prev.1) >= 0.8 else { return }
        }
        lastReported[id] = (p, now)
        let np = p
        DispatchQueue.main.async {
            guard abs((self.progress[id] ?? 0) - np) >= 0.002 else { return }
            self.progress[id] = np
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let m = ModelStore.shared.model(id: id) else { return }
        let dest = ModelStore.shared.localPath(for: m)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        do {
            try fm.moveItem(atPath: location.path, toPath: dest)
            lastReported.removeValue(forKey: id)
            DispatchQueue.main.async {
                self.downloadingIds.remove(id)
                self.progress[id] = nil
                self.triedMirror.remove(id)
                self.resumeData[id] = nil
                ModelStore.shared.refreshStates()
            }
            setMessage("\(m.name) 下载完成")
        } catch {
            setMessage("保存失败：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        guard let error = error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // 暂停导致的取消，不算失败

        lastReported.removeValue(forKey: id)
        let canFallback = !triedMirror.contains(id),
            model = ModelStore.shared.model(id: id),
            hasPrimary = model?.primaryURL != nil,
            name = model?.name ?? id
        if canFallback, hasPrimary {
            triedMirror.insert(id)
            setMessage("主源失败，切换镜像源重试：\(name)")
            if let m = model { start(m) }
        } else {
            setMessage("下载失败：\(error.localizedDescription)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
