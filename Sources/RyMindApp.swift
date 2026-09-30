import SwiftUI

@main
struct RyMindApp: App {
    @StateObject private var taskLock = TaskLock()
    @StateObject private var device = DeviceProfile()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(taskLock)
                .environmentObject(device)
                .preferredColorScheme(.dark)
        }
    }
}
