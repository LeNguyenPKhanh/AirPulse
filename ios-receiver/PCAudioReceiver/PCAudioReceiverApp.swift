import SwiftUI

@main
struct PCAudioReceiverApp: App {
    init() {
        // Activate mixed background audio session immediately on launch
        AudioSessionManager.shared.reconfigureSession()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
