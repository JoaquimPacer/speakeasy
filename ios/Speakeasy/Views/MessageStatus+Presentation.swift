import Foundation
import SwiftUI

extension MessageStatus {
    var displayTitle: String {
        switch self {
        case .sent:
            return "Sent"
        case .delivered:
            return "Delivered"
        case .watched:
            return "Watched"
        case .expired:
            return "Expired"
        }
    }

    var systemImage: String {
        switch self {
        case .sent:
            return "arrow.up.circle"
        case .delivered:
            return "checkmark.circle"
        case .watched:
            return "eye"
        case .expired:
            return "timer"
        }
    }

    var tint: Color {
        switch self {
        case .sent:
            return .blue
        case .delivered:
            return .green
        case .watched:
            return .purple
        case .expired:
            return .orange
        }
    }
}

extension Date {
    var relativeShortDisplay: String {
        RelativeDateTimeFormatter.shortSpeakeasy.localizedString(for: self, relativeTo: Date())
    }
}

extension Optional where Wrapped == Double {
    var durationDisplay: String {
        guard let seconds = self else {
            return "--:--"
        }

        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private extension RelativeDateTimeFormatter {
    static let shortSpeakeasy: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
