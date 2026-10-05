import AppKit
import Foundation
import StudioSession
import UserNotifications

// What an export says when it finishes: a notification when the studio is in the
// background, and the captions it wrote beside the movie. Split from
// `StudioDocumentModel+Export.swift` for the file-length cap.

extension StudioDocumentModel {
    /// A local notification when the studio window is not key (docs/16 STU-C6).
    ///
    /// Only the file name crosses into the task. The request is built after permission is
    /// granted, because `UNNotificationRequest` is not `Sendable` and capturing a finished
    /// one in the authorization callback handed a non-Sendable object across threads.
    func notifyExportFinished(at destination: URL) {
        // No app (a test host) is not "in the background": there is nobody to notify.
        guard NSApp?.isActive == false else { return }
        // Notification Center throws for a process with no bundle, which is a test runner.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let fileName = destination.lastPathComponent
        Task {
            let center = UNUserNotificationCenter.current()
            guard await (try? center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Export finished"
            content.body = fileName
            content.sound = .default
            try? await center.add(UNNotificationRequest(
                identifier: "studio.export.\(UUID().uuidString)",
                content: content,
                trigger: nil
            ))
        }
    }

    /// SRT and VTT beside the movie (docs/13 T2.2). Tiny, and the reason the transcript
    /// was persisted. Timed against the snapshot's clips, which are the movie's.
    ///
    /// They share the movie's name so players pick them up, and so they replace the
    /// captions of the movie this export just replaced. Both outcomes are said: files that
    /// appeared unannounced beside an export, or silently failed to, were a surprise
    /// either way (docs/18 STU P3).
    func writeCaptions(for snapshot: StudioExportSnapshot, beside destination: URL) {
        guard let transcript = snapshot.transcript else { return }
        let base = destination.deletingPathExtension()
        let srt = CaptionExport.srt(from: transcript, timeline: snapshot.edit.clips)
        let vtt = CaptionExport.vtt(from: transcript, timeline: snapshot.edit.clips)
        do {
            try Data(srt.utf8).write(to: base.appendingPathExtension("srt"), options: .atomic)
            try Data(vtt.utf8).write(to: base.appendingPathExtension("vtt"), options: .atomic)
            notice = "Captions saved beside the movie as .srt and .vtt."
        } catch {
            logger.error("Could not write captions: \(error.localizedDescription, privacy: .public)")
            notice = "The movie was exported, but its captions could not be saved."
        }
    }
}
