import Foundation

public extension AppCommand {
    /// This command with every file path made absolute against `directory`
    /// (docs/17 T-OUT-13).
    ///
    /// The CLI runs in the user's shell, but the agent that opens the file does not: its
    /// working directory is `/`, so `kadr pin shot.png` looked for `/shot.png`. The CLI
    /// resolves paths where the user typed them, before they leave the process.
    func resolvingPaths(against directory: URL) -> AppCommand {
        switch self {
        case let .pin(target):
            return .pin(target.map { $0.resolved(against: directory) })
        case let .annotate(target):
            return .annotate(target.resolved(against: directory))
        case let .addToHistory(target):
            return .addToHistory(target.resolved(against: directory))
        case let .addQuickAccessOverlay(target):
            return .addQuickAccessOverlay(target.resolved(against: directory))
        case var .captureText(options):
            if let path = options.path {
                options.path = FileTarget(path: path).resolved(against: directory).path
            }
            return .captureText(options)
        default:
            // Nothing else names a file.
            return self
        }
    }
}

public extension FileTarget {
    /// Absolute, with `~` expanded and `.`/`..` folded; an absolute path is kept as it is.
    func resolved(against directory: URL) -> FileTarget {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: directory)
        return FileTarget(path: url.standardizedFileURL.path)
    }
}
