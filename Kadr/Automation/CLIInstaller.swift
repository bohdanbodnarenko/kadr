import Foundation
import os
import Shared

/// Installs the `kadr` command line tool by symlink (docs/03 §8.4, §8.3 Advanced).
///
/// A symlink, not a copy: the tool inside the app bundle is the one that ships, so it is
/// always the same version as the agent it talks to, and an update replaces it for free.
/// Nothing here needs admin rights — `/usr/local/bin` is used when the user's setup already
/// makes it writable (Homebrew does), and `~/.local/bin` otherwise.
@MainActor
struct CLIInstaller {
    /// Where the tool ends up, and what it took to get there.
    enum Outcome: Equatable {
        case installed(URL)
        /// Installed somewhere that may not be on `PATH` yet.
        case installedNeedsPath(URL)
        case failed(String)
    }

    private let logger = KadrLog.logger(.settings)
    private let fileManager = FileManager.default

    /// The tool inside the app bundle. `nil` in a build that did not embed it.
    var bundledToolURL: URL? {
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("kadr")
        return fileManager.isExecutableFile(atPath: helpers.path) ? helpers : nil
    }

    /// Directories to try, best first.
    static let candidateDirectories: [URL] = [
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".local/bin", isDirectory: true)
    ]

    /// The link this install would create or replace, if one is already there.
    ///
    /// Only a link into a Kadr bundle counts. Another tool called `kadr` belongs to
    /// someone else, and Install and Remove used to replace or delete it (docs/17 T-OUT-13).
    var installedURL: URL? {
        Self.candidateDirectories
            .map { $0.appendingPathComponent("kadr") }
            .first { exists($0) && isKadrLink($0) }
    }

    /// Whether a symlink points at the tool inside some Kadr app bundle.
    nonisolated static func isKadrToolLink(destination: String?) -> Bool {
        guard let destination else { return false }
        return destination.hasSuffix(".app/Contents/Helpers/kadr")
    }

    private func isKadrLink(_ url: URL) -> Bool {
        Self.isKadrToolLink(destination: try? fileManager.destinationOfSymbolicLink(atPath: url.path))
    }

    /// Whether the link that exists points at *this* build.
    var isInstalled: Bool {
        guard let installedURL, let bundledToolURL else { return false }
        let destination = try? fileManager.destinationOfSymbolicLink(atPath: installedURL.path)
        return destination == bundledToolURL.path
    }

    @discardableResult
    func install() -> Outcome {
        guard let tool = bundledToolURL else {
            return .failed("This build does not include the command line tool.")
        }

        for directory in Self.candidateDirectories {
            guard prepare(directory) else { continue }
            let link = directory.appendingPathComponent("kadr")
            do {
                // Replacing our own link rather than refusing: re-running Install after an
                // update is the obvious thing to do, and it should just work. Anything else
                // with the name is left alone and the next directory is tried.
                if exists(link) {
                    guard isKadrLink(link) else {
                        logger.info("A different kadr is in \(directory.path, privacy: .public); leaving it")
                        continue
                    }
                    try fileManager.removeItem(at: link)
                }
                try fileManager.createSymbolicLink(at: link, withDestinationURL: tool)
            } catch {
                logger.error("Could not link into \(directory.path, privacy: .public)")
                continue
            }
            logger.info("Installed the CLI at \(link.path, privacy: .public)")
            return Self.isOnPath(directory) ? .installed(link) : .installedNeedsPath(link)
        }
        return .failed("Kadr could not write to /usr/local/bin or ~/.local/bin.")
    }

    /// What Remove did. A failure used to read "Nothing to remove." (docs/16 APP-7,
    /// docs/17 T-SH-8), which sent the user looking for a link that was still there.
    enum RemovalOutcome: Equatable {
        case removed
        case nothingInstalled
        case failed(String)

        var message: String {
            switch self {
            case .removed: String(localized: "Removed.")
            case .nothingInstalled: String(localized: "Nothing to remove.")
            case let .failed(reason): reason
            }
        }
    }

    @discardableResult
    func uninstall() -> RemovalOutcome {
        guard let installedURL else { return .nothingInstalled }
        do {
            try fileManager.removeItem(at: installedURL)
            logger.info("Removed the CLI at \(installedURL.path, privacy: .public)")
            return .removed
        } catch {
            logger.error("Could not remove \(installedURL.path, privacy: .public)")
            let path = installedURL.path
            return .failed(String(localized: "Kadr could not remove \(path). Remove it in Terminal with: rm \(path)"))
        }
    }

    /// Whether anything is at this path — including a dangling symlink, which
    /// `fileExists` reports as absent because it follows the link.
    private func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Creates the directory when it is one we own, and reports whether it is writable.
    ///
    /// `/usr/local/bin` is deliberately *not* created: making it is an admin operation,
    /// and an app that quietly asks for admin rights to install a convenience is exactly
    /// the kind of thing this project promises not to do.
    private func prepare(_ directory: URL) -> Bool {
        let isUserOwned = directory.path.hasPrefix(NSHomeDirectory())
        if isUserOwned, !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }
        return fileManager.isWritableFile(atPath: directory.path)
    }

    /// Whether a directory is on the `PATH` this process inherited.
    ///
    /// Only a hint: a GUI app's environment is not the shell's. It decides whether the UI
    /// says "installed" or "installed — add this to your PATH", nothing more.
    static func isOnPath(_ directory: URL) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { $0 == directory.path }
    }
}
