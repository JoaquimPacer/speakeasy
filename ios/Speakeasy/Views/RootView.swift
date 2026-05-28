import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: AppTab = .videos

    var body: some View {
        if appState.currentUser == nil {
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
                guard appState.currentUser != nil else {
                    appState.stopRemotePolling()
                    return
                }
                appState.startRemotePolling()
                await appState.refreshQuietly()
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    appState.startRemotePolling()
                    Task {
                        await appState.refreshQuietly()
                    }
                case .background:
                    appState.stopRemotePolling()
                    Task {
                        await appState.discardActivePlaybackFile()
                    }
                case .inactive:
                    break
                @unknown default:
                    break
                }
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
