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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(taskLock)
                .environmentObject(device)
                .environmentObject(ModelStore.shared)
                .environmentObject(ModelDownloader.shared)
                .preferredColorScheme(.dark)
        }
    }
}
