import Foundation
import SwiftUI

@main
struct SpeakeasyApp: App {
    @StateObject private var appState: AppState

    init() {
#if DEBUG
        let seedScreenshotPreview = ProcessInfo.processInfo.arguments.contains(
            "--kithra-screenshot-preview"
        )
#else
        let seedScreenshotPreview = false
#endif
        _appState = StateObject(
            wrappedValue: AppState(seedPreviewData: seedScreenshotPreview)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}
