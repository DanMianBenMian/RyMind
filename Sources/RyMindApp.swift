import SwiftUI

final class RyAppDelegate: NSObject, UIApplicationDelegate {
    /// 后台下载全部结束时的系统回调（不接这个，App 划后台时下载完不会被唤醒）
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelDownloader.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct RyMindApp: App {
    @UIApplicationDelegateAdaptor(RyAppDelegate.self) var appDelegate
    @StateObject private var taskLock = TaskLock()
    @StateObject private var device = DeviceProfile()
    @ObservedObject private var trace = RMTrace.shared

    init() {
        // 越早越好：崩了也要把栈写进日志
        RMTrace.shared.installHandlers()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"
        RMTrace.shared.log("启动 v\(v) build \(b)", tag: "app")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(taskLock)
                .environmentObject(device)
                .environmentObject(RMTrace.shared)
                .environmentObject(ModelStore.shared)
                .environmentObject(ModelDownloader.shared)
                .environmentObject(SessionStore.shared)
                .environmentObject(LlamaEngine.shared)
                .environmentObject(SkillStore.shared)
                .environmentObject(FileStore.shared)
                .preferredColorScheme(.dark)
        }
    }
}
