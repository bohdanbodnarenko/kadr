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
        /// `baseImagePNG`'s CRC-32, if the caller has it — see `KadrDocumentFile.crc32(of:)`.
        ///
        /// Must describe `baseImagePNG` exactly; a wrong value writes a zip other tools
        /// reject. Nil means "compute it".
        public var baseImageCRC32: UInt32?

        public init(document: AnnotationDocument, baseImagePNG: Data, baseImageCRC32: UInt32? = nil) {
            self.document = document
            self.baseImagePNG = baseImagePNG
            self.baseImageCRC32 = baseImageCRC32
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

    public enum FileError: Error, Equatable, LocalizedError {
        case missingEntry(String)
        case unsupportedVersion(Int)
        /// A command type this build cannot read, from a newer Kadr.
        case newerCommands
        case malformed(String)

        /// Sentences a person can act on; the detail stays in the log (docs/18 ED-8).
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion, .newerCommands:
                "This project was saved by a newer version of Kadr. Update Kadr to open it."
            case .missingEntry, .malformed:
                "This project file is damaged or is not a Kadr project."
            }
        }
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    private static func failsInsideCommands(_ error: DecodingError) -> Bool {
        let path: [any CodingKey] = switch error {
        case let .dataCorrupted(context), let .keyNotFound(_, context),
             let .typeMismatch(_, context), let .valueNotFound(_, context):
            context.codingPath
        @unknown default:
            []
        }
        return path.first?.stringValue == "commands" && path.count > 1
    }

    /// The project's annotations and base-image record, without the image itself.
    ///
    /// Public so autosave can write the small part on every edit and the base image once
    /// (docs/18 ED-10).
    public static func commandsJSON(for document: AnnotationDocument) throws -> Data {
        let payload = Payload(
            version: currentVersion,
            baseImage: encodedBaseImage(of: document),
            commands: document.commands
        )
        let encoder = JSONEncoder()
        // Sorted and pretty so a `.kadr` diffs usefully in version control.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(payload)
    }

    public static func data(for contents: Contents) throws -> Data {
        let json = try commandsJSON(for: contents.document)
        return ZipArchive.archive([
            ZipArchive.Entry(name: baseImageEntry, data: contents.baseImagePNG, crc: contents.baseImageCRC32),
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
        return try contents(commandsJSON: json, baseImagePNG: image)
    }

    /// Reassembles a project from `commandsJSON(for:)` and its base image.
    public static func contents(commandsJSON json: Data, baseImagePNG image: Data) throws -> Contents {
        // The version first: a newer file may not decode at all, and "malformed" is the
        // wrong thing to tell someone whose file is fine (docs/18 ED-8).
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: json), probe.version > currentVersion {
            throw FileError.unsupportedVersion(probe.version)
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: json)
        } catch let error as DecodingError where Self.failsInsideCommands(error) {
            // A command this build does not know: written by a newer Kadr with the same
            // file version, not a broken file.
            throw FileError.newerCommands
        } catch {
            throw FileError.malformed(String(describing: error))
        }

        return Contents(
            document: AnnotationDocument(baseImage: payload.baseImage, commands: payload.commands),
            baseImagePNG: image
        )
    }

    /// The checksum a `.kadr` stores for `data`, for callers that write the same base image
    /// repeatedly and want to compute it once (autosave, docs/10 R2.6).
    public static func crc32(of data: Data) -> UInt32 {
        ZipArchive.crc32(data)
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
