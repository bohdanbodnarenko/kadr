import AppKit
import SwiftUI

/// `NSSearchField`, wrapped (docs/03 §5 P3).
///
/// AppKit's own control rather than a styled `TextField`: it brings the magnifier, the
/// clear button, Escape-to-clear and the recents menu behaviour macOS users already expect
/// from a search field, none of which SwiftUI offers outside a `.searchable` navigation
/// container that this window does not have.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Search captures"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        // Only when it differs, or typing into the field would fight with the binding.
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
