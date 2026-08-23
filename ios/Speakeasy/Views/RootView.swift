import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: AppTab = .videos

    var body: some View {
        Group {
            if appState.isRestoringSession {
                ProgressView("Restoring protected session")
            } else if appState.currentUser == nil {
                NavigationStack {
                    SetupView()
                }
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        ConversationListView()
                    }
                    .tabItem {
                        Label("Videos", systemImage: "video.fill")
                    }
                    .tag(AppTab.videos)

                    NavigationStack {
                        SettingsStorageView {
                            selectedTab = .videos
                        }
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(AppTab.settings)
                }
                .task(id: appState.currentUser?.id) {
                    guard appState.currentUser != nil,
                          scenePhase == .active else {
                        appState.stopRemotePolling()
                        return
                    }
                    appState.resumePlaintextProductionAfterBecomingActive()
                    appState.startRemotePolling()
                    await appState.refreshQuietly()
                }
            }
        }
        .task {
            if scenePhase == .active {
                appState.resumePlaintextProductionAfterBecomingActive()
            } else {
                appState.invalidatePlaintextProductionForBackground()
            }
            await appState.cleanupInvalidatedPlaintextFiles()
            await appState.mediaPipeline.cleanupAbandonedPlaintextTemporaryFiles()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                appState.resumePlaintextProductionAfterBecomingActive()
                Task {
                    await appState.cleanupInvalidatedPlaintextFiles()
                }
                guard appState.currentUser != nil else {
                    return
                }
                appState.startRemotePolling()
                Task {
                    await appState.refreshQuietly()
                }
            case .inactive:
                appState.stopRemotePolling()
                appState.invalidatePlaintextProductionForBackground()
                Task {
                    await appState.cleanupInvalidatedPlaintextFiles()
                }
            case .background:
                appState.stopRemotePolling()
                appState.invalidatePlaintextProductionForBackground()
                Task {
                    await appState.cleanupInvalidatedPlaintextFiles()
                    await appState.mediaPipeline.cleanupAbandonedPlaintextTemporaryFiles()
                }
            @unknown default:
                break
            }
        }
    }
}

private enum AppTab: Hashable {
    case videos
    case settings
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(AppState())
    }
}
