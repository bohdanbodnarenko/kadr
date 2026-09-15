import Foundation

/// The user-facing project beside a recording session (docs/09 U3.1).
///
/// The folder is still named for when it was recorded — that keeps it unique on disk —
/// but History and the studio window should say "Onboarding walkthrough", not
/// `2026-09-01-142233`.
public struct SessionProject: Sendable, Hashable, Codable {
    public var displayName: String
    public var lastOpenedAt: Date?

    public init(displayName: String, lastOpenedAt: Date? = nil) {
        self.displayName = displayName
        self.lastOpenedAt = lastOpenedAt
    }
}

public extension RecordingSession {
    /// Sidecar that holds the project title. Missing means use the folder name.
    var projectURL: URL {
        directory.appendingPathComponent("project.json")
    }

    /// The folder's stem, used when nobody has renamed the recording yet.
    var folderName: String {
        directory.deletingPathExtension().lastPathComponent
    }

    /// What History and the studio window should call this recording.
    var displayName: String {
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONDecoder().decode(SessionProject.self, from: data)
        else {
            return folderName
        }
        let trimmed = project.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? folderName : trimmed
    }

    /// Names the project. Empty strings are ignored so a blank rename cannot hide it.
    func setDisplayName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var project = (try? JSONDecoder().decode(SessionProject.self, from: Data(contentsOf: projectURL)))
            ?? SessionProject(displayName: trimmed)
        project.displayName = trimmed
        let data = try JSONEncoder().encode(project)
        try data.write(to: projectURL, options: .atomic)
    }

    /// Touches last-opened so Recent Recordings can sort by it (docs/16 STU-C9).
    func markOpened() {
        var project = (try? JSONDecoder().decode(SessionProject.self, from: Data(contentsOf: projectURL)))
            ?? SessionProject(displayName: displayName)
        project.lastOpenedAt = Date()
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: projectURL, options: .atomic)
        }
    }
}
