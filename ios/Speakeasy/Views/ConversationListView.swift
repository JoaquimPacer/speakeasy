import Foundation
import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingRecorder = false

    var body: some View {
        List {
            if appState.conversations.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            } else {
                ForEach(appState.conversations) { conversation in
                    NavigationLink(value: conversation.contact) {
                        ConversationRow(conversation: conversation)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Kithra")
        .navigationDestination(for: Contact.self) { contact in
            ConversationTimelineView(contact: contact)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingRecorder = true
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack {
                RecordingPlaceholderView(contact: nil)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No conversations")
                .font(.headline)
            Text("Create an invite or accept one to start exchanging encrypted videos.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding()
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(conversation.contact.displayName)
                        .font(.headline)
                    Spacer()
                    if let latest = conversation.latestMessage {
                        Text(latest.createdAt.relativeShortDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    if let latest = conversation.latestMessage {
                        Label(latest.status.displayTitle, systemImage: latest.status.systemImage)
                            .font(.caption)
                            .foregroundStyle(latest.status.tint)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(latest.blobSize), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Ready", systemImage: "video")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle())
            }
        }
        .padding(.vertical, 8)
    }

    private var initials: String {
        let words = conversation.contact.displayName
            .split(separator: " ")
            .prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "S" : value.uppercased()
    }
}

#Preview {
    NavigationStack {
        ConversationListView()
    }
    .environmentObject(AppState())
}
