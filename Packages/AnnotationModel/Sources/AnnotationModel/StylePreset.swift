import CoreGraphics
import Foundation

/// A whole look, saved by name (docs/09 U1.5).
///
/// The unit that matters is the *combination*. A background alone is not a look: the same
/// gradient with a hard shadow and no tilt is a different picture from the same gradient
/// with a soft shadow and a lean. Saving each effect separately would mean rebuilding the
/// combination by hand every time, which is what the preset exists to avoid.
///
/// Every field is optional and every field defaults on decode. A preset saved by a later
/// Kadr with a fifth effect in it still opens here — it simply arrives without that effect
/// rather than failing to arrive at all (docs/08 §2.6).
public struct StylePreset: Codable, Hashable, Sendable, Identifiable {
    /// Bumped when a field's *meaning* changes, as against a field being added. Adding is
    /// handled by the defaults; changing is not, and needs somewhere to hang a migration.
    public static let currentVersion = 1

    public var id: UUID
    public var name: String
    public var version: Int
    public var beautify: BeautifySpec?
    public var camera: AnnotationCameraSpec?
    public var progressiveBlur: ProgressiveBlurSpec?
    public var watermark: WatermarkSpec?

    public init(
        id: UUID = UUID(),
        name: String,
        version: Int = StylePreset.currentVersion,
        beautify: BeautifySpec? = nil,
        camera: AnnotationCameraSpec? = nil,
        progressiveBlur: ProgressiveBlurSpec? = nil,
        watermark: WatermarkSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.beautify = beautify
        self.camera = camera
        self.progressiveBlur = progressiveBlur
        self.watermark = watermark
    }

    /// The look a document is currently wearing.
    public init(name: String, capturing document: AnnotationDocument) {
        self.init(
            name: name,
            beautify: document.beautify,
            camera: document.camera,
            progressiveBlur: document.progressiveBlur,
            watermark: document.watermark
        )
    }

    /// Whether a document is wearing exactly this look.
    ///
    /// Identities are excluded from the comparison, because a preset's identity is its
    /// *appearance*: applying a preset gives the document new command ids, and a preset
    /// that stopped matching the instant it was applied would be useless.
    public func matches(_ document: AnnotationDocument) -> Bool {
        StylePreset(name: name, capturing: document).appearance == appearance
    }

    /// Everything about this preset except its name and the ids inside it.
    ///
    /// Public because "are these two looks the same" is a question the inspector asks as
    /// well as `matches` does.
    public var appearance: StylePreset {
        var stripped = self
        stripped.id = Self.comparisonID
        stripped.name = ""
        stripped.version = Self.currentVersion
        stripped.beautify?.id = AnnotationID(Self.comparisonID)
        stripped.camera?.id = AnnotationID(Self.comparisonID)
        stripped.progressiveBlur?.id = AnnotationID(Self.comparisonID)
        stripped.watermark?.id = AnnotationID(Self.comparisonID)
        return stripped
    }

    /// A fixed id used only to neutralise identity during comparison.
    private static let comparisonID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()

    /// Whether this preset would change anything at all.
    public var isEmpty: Bool {
        beautify == nil && camera == nil && progressiveBlur == nil && watermark == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, beautify, camera, progressiveBlur, watermark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled",
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            beautify: container.decodeIfPresent(BeautifySpec.self, forKey: .beautify),
            camera: container.decodeIfPresent(AnnotationCameraSpec.self, forKey: .camera),
            progressiveBlur: container.decodeIfPresent(
                ProgressiveBlurSpec.self,
                forKey: .progressiveBlur
            ),
            watermark: container.decodeIfPresent(WatermarkSpec.self, forKey: .watermark)
        )
    }

    // MARK: - Built-ins

    public static let builtIn: [StylePreset] = [
        StylePreset(name: "Clean White", beautify: .cleanWhite),
        StylePreset(name: "Twitter / X", beautify: .twitter),
        StylePreset(name: "Instagram", beautify: .instagram),
        StylePreset(name: "Story", beautify: .story),
        StylePreset(name: "Edge Bleed", beautify: .stuckBottom),
        StylePreset(
            name: "Hero Lean",
            beautify: BeautifySpec(
                padding: .relative(0.14),
                cornerRadius: .relative(0.03),
                backdrop: .gradient(BeautifyPalette.gradients[10]),
                shadow: .soft,
                aspect: .sixteenNine,
                border: .mount
            ),
            camera: .lean
        ),
        StylePreset(
            name: "Focus",
            beautify: BeautifySpec(
                padding: .relative(0.1),
                backdrop: .gradient(BeautifyPalette.gradients[5]),
                shadow: .soft
            ),
            progressiveBlur: .focus
        )
    ]
}

public extension AnnotationDocument {
    /// Wears a whole look, in one undo step (docs/09 U1.5).
    ///
    /// One step, not four: applying a preset is a single decision, and undoing it should
    /// take one press. Doing it through the four individual setters would leave four
    /// entries on the stack, three of which show a half-applied look nobody chose.
    mutating func applyStylePreset(_ preset: StylePreset) {
        var updated = commands.filter { command in
            switch command {
            case .beautify, .camera, .progressiveBlur, .watermark: false
            default: true
            }
        }
        // Reverse order, because each insert goes to the front: the chrome ends up in the
        // same order a document that grew it one effect at a time would have.
        if let watermark = preset.watermark, !watermark.isIdentity {
            updated.insert(.watermark(watermark), at: 0)
        }
        if let blur = preset.progressiveBlur, !blur.isIdentity {
            updated.insert(.progressiveBlur(blur), at: 0)
        }
        if let camera = preset.camera, !camera.isIdentity {
            updated.insert(.camera(camera), at: 0)
        }
        if let beautify = preset.beautify {
            updated.insert(.beautify(beautify), at: 0)
        }
        guard updated != commands else { return }
        pushHistory(updated)
    }

    /// The preset the document currently matches, if any.
    ///
    /// What makes the inspector able to say "Hero Lean (edited)" rather than showing a
    /// stale name next to a look that no longer resembles it.
    func matchingStylePreset(among presets: [StylePreset]) -> StylePreset? {
        presets.first { $0.matches(self) }
    }
}
