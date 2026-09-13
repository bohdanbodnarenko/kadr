import CoreGraphics
import Foundation

/// The `.kadr` project file: a zip of the base PNG and the command list (docs/04 §6).
///
/// Keeping the base image and the annotations side by side, rather than flattening, is
/// what makes a `.kadr` re-editable forever — and keeping it a plain zip means anyone can
/// open it and get their screenshot back even without Kadr.
public enum KadrDocumentFile {
    public static let fileExtension = "kadr"

    static let baseImageEntry = "base.png"
    static let commandsEntry = "commands.json"

    /// What a `.kadr` file contains.
    public struct Contents: Sendable {
        public var document: AnnotationDocument
        /// The untouched base image, as PNG data.
        public var baseImagePNG: Data

        public init(document: AnnotationDocument, baseImagePNG: Data) {
            self.document = document
            self.baseImagePNG = baseImagePNG
        }
    }

    /// The JSON payload, versioned so a later format can be recognised rather than
    /// misread.
    struct Payload: Codable {
        var version: Int
        var baseImage: BaseImageReference
        var commands: [AnnotationCommand]
    }

    public static let currentVersion = 1

    public enum FileError: Error, Equatable {
        case missingEntry(String)
        case unsupportedVersion(Int)
        case malformed(String)
    }

    public static func data(for contents: Contents) throws -> Data {
        let payload = Payload(
            version: currentVersion,
            baseImage: encodedBaseImage(of: contents.document),
            commands: contents.document.commands
        )
        let encoder = JSONEncoder()
        // Sorted and pretty so a `.kadr` diffs usefully in version control.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try encoder.encode(payload)

        return ZipArchive.archive([
            ZipArchive.Entry(name: baseImageEntry, data: contents.baseImagePNG),
            ZipArchive.Entry(name: commandsEntry, data: json)
        ])
    }

    public static func contents(of data: Data) throws -> Contents {
        let entries = try ZipArchive.entries(in: data)

        guard let image = entries.first(where: { $0.name == baseImageEntry })?.data else {
            throw FileError.missingEntry(baseImageEntry)
        }
        guard let json = entries.first(where: { $0.name == commandsEntry })?.data else {
            throw FileError.missingEntry(commandsEntry)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: json)
        } catch {
            throw FileError.malformed(String(describing: error))
        }
        guard payload.version <= currentVersion else {
            throw FileError.unsupportedVersion(payload.version)
        }

        return Contents(
            document: AnnotationDocument(baseImage: payload.baseImage, commands: payload.commands),
            baseImagePNG: image
        )
    }

    public static func write(_ contents: Contents, to url: URL) throws {
        try data(for: contents).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Contents {
        try contents(of: Data(contentsOf: url))
    }

    /// Current orientation lives on the document's history; the file stores it on the
    /// base-image record so a `.kadr` reopens already rotated.
    private static func encodedBaseImage(of document: AnnotationDocument) -> BaseImageReference {
        var reference = document.baseImage
        reference.orientation = document.orientationHistory[document.historyIndex]
        return reference
    }
}
