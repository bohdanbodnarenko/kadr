import AnnotationModel
import AppKit
import MediaExport
import Shared
import UniformTypeIdentifiers

/// The format and quality controls under Save As (docs/03 §3 Export, docs/18 ED-12).
///
/// The panel used to offer formats only through the file extension, and JPEG or HEIC were
/// always written at the default quality. Choosing a format here changes the extension; the
/// quality slider applies to the lossy formats and is disabled for PNG and projects.
@MainActor
final class SaveAsAccessory: NSObject {
    enum Choice: Equatable {
        case image(ImageFormat)
        case project
    }

    let view: NSView
    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality:")
    private let choices: [Choice]
    private weak var panel: NSSavePanel?

    /// The quality for a lossy format, 0…1.
    var quality: Double {
        qualitySlider.doubleValue
    }

    init(panel: NSSavePanel, initial: Choice) {
        self.panel = panel
        choices = ImageFormat.writable.map(Choice.image) + [.project]

        let formatLabel = NSTextField(labelWithString: "Format:")
        for choice in choices {
            formatPopup.addItem(withTitle: Self.title(for: choice))
        }
        formatPopup.selectItem(at: choices.firstIndex(of: initial) ?? 0)
        qualitySlider.controlSize = .small
        qualitySlider.setAccessibilityLabel("Quality")

        let row = NSStackView(views: [formatLabel, formatPopup, qualityLabel, qualitySlider])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        qualitySlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        view = row
        super.init()

        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        apply(initial)
    }

    static func title(for choice: Choice) -> String {
        switch choice {
        case let .image(format): format.title
        case .project: "Kadr Project"
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        apply(choices[sender.indexOfSelectedItem])
    }

    private func apply(_ choice: Choice) {
        let type: UTType? = switch choice {
        case let .image(format): format.contentType
        case .project: UTType(filenameExtension: KadrDocumentFile.fileExtension)
        }
        if let type {
            panel?.allowedContentTypes = [type]
        }
        let lossy = if case let .image(format) = choice {
            format.isLossy
        } else {
            false
        }
        qualitySlider.isEnabled = lossy
        qualityLabel.textColor = lossy ? .labelColor : .disabledControlTextColor
    }
}
