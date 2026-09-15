import Foundation

/// The look applied to every new capture, stored in Application Support (docs/16 ED-16).
///
/// JSON of a `StylePreset`. The agent applies it through `CaptureProject` using only
/// AnnotationModel (CLAUDE.md rule 2).
public enum DefaultCaptureLook {
    public static let fileName = "default-look.json"

    public static func folder() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Kadr", isDirectory: true)
    }

    public static func fileURL() -> URL? {
        folder()?.appendingPathComponent(fileName)
    }

    public static func load() -> StylePreset? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let preset = try? JSONDecoder().decode(StylePreset.self, from: data)
        else {
            return nil
        }
        return preset.sanitized()
    }

    public static func save(_ preset: StylePreset) throws {
        guard let folder = folder() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(preset.sanitized())
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    public static func clear() {
        guard let url = fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
