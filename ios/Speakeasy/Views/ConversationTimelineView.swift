import SwiftUI

struct ConversationTimelineView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingRecorder = false

    let contact: Contact

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(appState.messages(for: contact)) { message in
                    VideoMessageBubble(
                        message: message,
                        direction: message.direction(for: appState.currentUser?.id)
                    )
                    .id(message.id)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            recordBar
        }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack {
                RecordingPlaceholderView(contact: contact)
            }
        }
    }

    private var recordBar: some View {
        HStack(spacing: 12) {
            Button {
                showingRecorder = true
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Refresh messages")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct VideoMessageBubble: View {
    let message: Message
    let direction: MessageDirection

    var body: some View {
        HStack {
            if direction == .sent {
                Spacer(minLength: 48)
            }

            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(direction == .sent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    VStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(direction == .sent ? .white : Color.accentColor)
                        Text(message.envelope.media.durationSeconds.durationDisplay)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(direction == .sent ? .white : .primary)
                    }
                }
                .frame(width: 190, height: 250)

                HStack(spacing: 8) {
                    Label(message.status.displayTitle, systemImage: message.status.systemImage)
                        .foregroundStyle(message.status.tint)
                    Text(message.createdAt.relativeShortDisplay)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if direction == .received {
                Spacer(minLength: 48)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ConversationTimelineView(contact: PreviewData.sample.contacts[0])
    }
    .environmentObject(AppState())
}

