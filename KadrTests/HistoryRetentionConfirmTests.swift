import Foundation
import HistoryKit
import Testing
@testable import Kadr

/// Choosing "This session only" says what the next launch will delete (docs/18 SH-2).
@Suite("Session-only retention confirmation")
@MainActor
struct HistoryRetentionConfirmTests {
    @Test("The message names the count, the size and that it can't be undone", arguments: [
        (1, "The 1 capture"),
        (42, "The 42 captures")
    ])
    func message(count: Int, expectedPrefix: String) {
        let usage = HistoryStorageUsage(itemCount: count, byteCount: 5_000_000)
        let message = PendingRetentionChange.sessionOnlyMessage(for: usage)
        #expect(message.hasPrefix(expectedPrefix))
        #expect(message.contains(ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)))
        #expect(message.hasSuffix("This can't be undone."))
    }
}
