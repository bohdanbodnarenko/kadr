import AppKit

extension StudioDocumentModel {
    /// Says `text` to VoiceOver (docs/17 T-STU-11). A banner that appears is silent to
    /// someone who cannot see it, so exports, notices and failures are announced too.
    static func announce(_ text: String?, unless unchanged: Bool = false) {
        guard let text, !unchanged, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
