import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ConversationListView()
            }
            .tabItem {
                Label("Videos", systemImage: "video.fill")
            }

            NavigationStack {
                SettingsStorageView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
}

