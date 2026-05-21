import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var relayBaseURLString: String
    @Published var currentUser: SpeakeasyUser?
    @Published var deviceIdentity: DevicePublicIdentity?
    @Published var contacts: [Contact]
    @Published var conversations: [ConversationSummary]
    @Published var messagesByContactID: [UUID: [Message]]

    let apiClient: SpeakeasyAPIClient
    let keyManager: DeviceKeyManaging
    let mediaPipeline: MediaPipelining

    init(
        relayBaseURL: URL = URL(string: "https://api.yourdomain.com")!,
        apiClient: SpeakeasyAPIClient? = nil,
        keyManager: DeviceKeyManaging = KeychainDeviceKeyManager(),
        mediaPipeline: MediaPipelining = DefaultMediaPipeline(),
        seedPreviewData: Bool = true
    ) {
        self.relayBaseURLString = relayBaseURL.absoluteString
        self.apiClient = apiClient ?? SpeakeasyAPIClient(configuration: APIConfiguration(baseURL: relayBaseURL))
        self.keyManager = keyManager
        self.mediaPipeline = mediaPipeline

        if seedPreviewData {
            let preview = PreviewData.sample
            self.currentUser = preview.currentUser
            self.deviceIdentity = preview.deviceIdentity
            self.contacts = preview.contacts
            self.conversations = preview.conversations
            self.messagesByContactID = preview.messagesByContactID
        } else {
            self.currentUser = nil
            self.deviceIdentity = nil
            self.contacts = []
            self.conversations = []
            self.messagesByContactID = [:]
        }
    }

    func messages(for contact: Contact) -> [Message] {
        messagesByContactID[contact.contactID, default: []]
            .sorted { $0.createdAt < $1.createdAt }
    }

    func updateRelayBaseURL(_ text: String) {
        relayBaseURLString = text
        guard let url = URL(string: text) else {
            return
        }

        Task {
            await apiClient.updateBaseURL(url)
        }
    }
}
