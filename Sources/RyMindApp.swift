import SwiftUI

@main
struct RyMindApp: App {
    @StateObject private var taskLock = TaskLock()
    @StateObject private var device = DeviceProfile()
    @StateObject private var store = ModelStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(taskLock)
                .environmentObject(device)
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
