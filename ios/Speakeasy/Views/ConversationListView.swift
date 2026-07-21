import Foundation
import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingRecorder = false
    @State private var contactMenuTarget: Contact?
    @State private var pendingContactAction: ContactAction?

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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            queue(.delete, for: conversation.contact)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            queue(.block, for: conversation.contact)
                        } label: {
                            Label("Block", systemImage: "hand.raised.fill")
                        }
                        .tint(.orange)

                        Button {
                            contactMenuTarget = conversation.contact
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .tint(.gray)
                    }
                    .contextMenu {
                        Button {
                            queue(.report, for: conversation.contact)
                        } label: {
                            Label("Report Contact", systemImage: "exclamationmark.bubble")
                        }

                        Button(role: .destructive) {
                            queue(.block, for: conversation.contact)
                        } label: {
                            Label("Block Contact", systemImage: "hand.raised.fill")
                        }

                        Button(role: .destructive) {
                            queue(.delete, for: conversation.contact)
                        } label: {
                            Label("Delete Contact", systemImage: "trash")
                        }
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
        .refreshable {
            await appState.refresh()
        }
        .confirmationDialog(
            contactMenuTarget?.displayName ?? "Contact",
            isPresented: showingContactMenu,
            titleVisibility: .visible
        ) {
            if let contact = contactMenuTarget {
                Button("Report Contact") {
                    queue(.report, for: contact)
                    contactMenuTarget = nil
                }

                Button("Block Contact", role: .destructive) {
                    queue(.block, for: contact)
                    contactMenuTarget = nil
                }

                Button("Delete Contact", role: .destructive) {
                    queue(.delete, for: contact)
                    contactMenuTarget = nil
                }
            }

            Button("Cancel", role: .cancel) {
                contactMenuTarget = nil
            }
        }
        .confirmationDialog(
            pendingContactAction?.title ?? "Contact",
            isPresented: showingActionConfirmation,
            titleVisibility: .visible
        ) {
            if let action = pendingContactAction {
                Button(action.confirmButtonTitle, role: action.buttonRole) {
                    let selectedAction = action
                    pendingContactAction = nil
                    Task {
                        await perform(selectedAction)
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                pendingContactAction = nil
            }
        } message: {
            if let action = pendingContactAction {
                Text(action.message)
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

    private var showingContactMenu: Binding<Bool> {
        Binding {
            contactMenuTarget != nil
        } set: { isPresented in
            if !isPresented {
                contactMenuTarget = nil
            }
        }
    }

    private var showingActionConfirmation: Binding<Bool> {
        Binding {
            pendingContactAction != nil
        } set: { isPresented in
            if !isPresented {
                pendingContactAction = nil
            }
        }
    }

    private func queue(_ kind: ContactAction.Kind, for contact: Contact) {
        pendingContactAction = ContactAction(kind: kind, contact: contact)
    }

    private func perform(_ action: ContactAction) async {
        switch action.kind {
        case .delete:
            await appState.deleteContact(action.contact)
        case .block:
            await appState.blockContact(action.contact)
        case .report:
            await appState.reportContact(action.contact)
        }
    }
}

private struct ContactAction: Identifiable, Hashable {
    enum Kind: Hashable {
        case delete
        case block
        case report
    }

    var id: String { "\(kind)-\(contact.id.uuidString)" }
    var kind: Kind
    var contact: Contact

    var title: String {
        switch kind {
        case .delete:
            return "Delete \(contact.displayName)?"
        case .block:
            return "Block \(contact.displayName)?"
        case .report:
            return "Report \(contact.displayName)?"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .delete:
            return "Delete Contact"
        case .block:
            return "Block Contact"
        case .report:
            return "Submit Report"
        }
    }

    var buttonRole: ButtonRole? {
        switch kind {
        case .delete, .block:
            return .destructive
        case .report:
            return nil
        }
    }

    var message: String {
        switch kind {
        case .delete:
            return "This removes the conversation from your contact list on this device and relay account. It does not block future invites."
        case .block:
            return "This removes the conversation and prevents this contact from sending new videos to you."
        case .report:
            return "This sends a metadata-only report. Kithra does not upload decrypted video content."
        }
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

struct ConversationListView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            ConversationListView()
        }
        .environmentObject(AppState())
    }
}
