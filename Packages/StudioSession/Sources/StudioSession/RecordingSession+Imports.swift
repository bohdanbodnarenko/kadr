import CryptoKit
import Foundation

/// Imported soundtracks and wallpapers (docs/09 U3.3, docs/17 T-STU-1, T-STU-9).
///
/// Content-addressed, and kept until the edit is committed, so a swap changes the render
/// stamp and undo can still reach a replaced file.
public extension RecordingSession {
    /// Base name for an imported soundtrack. The picked file is copied in with its own
    /// extension so a WAV stays a WAV.
    static let soundtrackBaseName = "soundtrack"

    /// Imported replacement audio files currently in this session.
    var soundtrackURLs: [URL] {
        imports(named: Self.soundtrackBaseName)
    }

    /// The soundtrack named in `edit`, if that file is still here.
    func soundtrackURL(for edit: StudioEdit) -> URL? {
        importURL(named: edit.soundtrackFileName)
    }

    /// Copies `url` in as a soundtrack and returns the name to store in the edit.
    ///
    /// Content-addressed (docs/17 T-STU-1): the name carries a hash of the file, so
    /// swapping one soundtrack for another changes the edit, and a render stamped with
    /// the old one is never handed back for the new one. Earlier imports are left in
    /// place so undoing a replacement or a removal still finds its file (T-STU-9);
    /// `purgeUnusedImports(keeping:)` clears them once the edit is committed.
    func replaceSoundtrack(copying url: URL) throws -> String {
        try importFile(url, baseName: Self.soundtrackBaseName, defaultExtension: "m4a")
    }

    func removeSoundtracks() throws {
        for existing in soundtrackURLs {
            try FileManager.default.removeItem(at: existing)
        }
    }

    /// Base name for an imported canvas wallpaper. Copied in with its own extension.
    static let wallpaperBaseName = "wallpaper"

    /// Imported wallpaper files currently in this session.
    var wallpaperURLs: [URL] {
        imports(named: Self.wallpaperBaseName)
    }

    /// The wallpaper named in `edit`, if that file is still here.
    func wallpaperURL(for edit: StudioEdit) -> URL? {
        importURL(named: edit.canvas.wallpaperFileName)
    }

    /// Copies `url` in as a wallpaper, content-addressed like a soundtrack.
    func replaceWallpaper(copying url: URL) throws -> String {
        try importFile(url, baseName: Self.wallpaperBaseName, defaultExtension: "png")
    }

    func removeWallpapers() throws {
        for existing in wallpaperURLs {
            try FileManager.default.removeItem(at: existing)
        }
    }

    /// Deletes every imported soundtrack and wallpaper `edit` does not use.
    ///
    /// Run when the edit is committed on close: until then undo may still reach back to
    /// a file the user replaced or removed.
    func purgeUnusedImports(keeping edit: StudioEdit) {
        let kept = Set([soundtrackURL(for: edit), wallpaperURL(for: edit)].compactMap(\.self))
        for url in soundtrackURLs + wallpaperURLs where !kept.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// What identifies an import's content, for the render stamp (docs/17 T-STU-1).
    ///
    /// A content-addressed name already is its content's identity. A file imported
    /// before names were hashed is read and hashed, so swapping it is still noticed.
    static func contentIdentity(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        for base in [soundtrackBaseName, wallpaperBaseName] where stem.hasPrefix(base + "-") {
            return stem
        }
        return try? contentDigest(of: url)
    }

    /// Whether `url` is an import with `baseName`: the legacy fixed name, or a hashed one.
    static func isImport(_ url: URL, named baseName: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem == baseName || stem.hasPrefix(baseName + "-")
    }

    private func imports(named baseName: String) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { Self.isImport($0, named: baseName) }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
    }

    private func importURL(named name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = directory
            .appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func importFile(_ url: URL, baseName: String, defaultExtension: String) throws -> String {
        let ext = url.pathExtension.lowercased()
        let digest = try Self.contentDigest(of: url)
        let fileName = "\(baseName)-\(digest).\(ext.isEmpty ? defaultExtension : ext)"
        let destination = directory.appendingPathComponent(fileName)
        // Same content, same name: the file already here is this one.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return fileName
    }

    /// The first 16 hex digits of the file's SHA-256, read in chunks so a long
    /// soundtrack is never loaded whole.
    static func contentDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
