import SwiftUI

@main
struct SpeakeasyApp: App {
    @StateObject private var appState = AppState(seedPreviewData: false)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}
