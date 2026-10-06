import AnnotationModel
import AppKit
import EditorUI
import Foundation
import os

/// Unsaved work: the recovery copy, the edited dot, and the remembered styles (docs/07 M7,
/// docs/16 ED-6, ED-7).
extension EditorWindowController {
    /// ⌘Q and the close sheet both need a durable copy before the process dies (docs/16 ED-7).
    func flushAutosaveSynchronously() {
        autosaveTask?.cancel()
        flushStyleMemory()
        writeAutosave(synchronously: true)
    }

    /// Offers work a previous session left behind — a crash, a force quit, a power cut.
    func offerRecoveryIfAny() {
        guard let window, let recovered = autosave.read(for: documentURL) else { return }
        // Orientation counts: a rotate or flip with no annotation is still unsaved work
        // (docs/18 ED-10).
        guard recovered.document.commands != model.document.commands
            || recovered.document.orientation != model.document.orientation
        else {
            autosave.discard(for: documentURL)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Kadr has unsaved changes to “\(documentURL.lastPathComponent)”.")
        alert.informativeText = String(localized: "The editor closed before these annotations were saved.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.alertStyle = .informational

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                model.replaceDocument(recovered.document)
                if let exportScale = recovered.exportScale {
                    model.exportScale = CGFloat(exportScale)
                }
                // A recovered copy may predate the measurement this window made. One still in
                // flight adopts into whatever document is current when it lands.
                if let measuredVisibleBounds {
                    model.adoptVisibleBounds(measuredVisibleBounds)
                }
                logger.info("Restored autosaved annotations")
            } else {
                autosave.discard(for: documentURL)
            }
        }
    }

    /// Re-arms itself after every change, which is how Observation reports more than once.
    ///
    /// Coalesced: one pending reaction at a time, however many changes arrive before it
    /// runs. A pointer drag does not publish the document per mouse-move any more, but an
    /// inspector slider still does, and this used to encode the style memory, write the
    /// defaults, compare the whole command history twice and restart the autosave timer
    /// for every tick of it.
    func trackChangesForAutosave() {
        withObservationTracking {
            _ = model.document
            _ = model.styleMemory
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleChangeHandling()
            }
        }
    }

    private func scheduleChangeHandling() {
        guard pendingChangeTask == nil else { return }
        pendingChangeTask = Task { [weak self] in
            guard let self else { return }
            pendingChangeTask = nil
            trackChangesForAutosave()
            handleDocumentChange()
        }
    }

    private func handleDocumentChange() {
        scheduleStyleMemorySave()
        // Mid-gesture — an inspector slider, a text box being typed into — the state is
        // not one worth recording yet. The gesture's end is itself a change, and lands here.
        guard !model.document.isGestureOpen else { return }
        // Once per reaction: it compares the command list with the saved one.
        let unsaved = model.hasUnsavedChanges
        if window?.isDocumentEdited != unsaved {
            window?.isDocumentEdited = unsaved
        }
        scheduleAutosave(unsaved: unsaved)
    }

    private func scheduleStyleMemorySave() {
        guard model.styleMemory != savedStyleMemory else { return }
        styleMemoryTask?.cancel()
        styleMemoryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.styleMemorySettleMilliseconds))
            guard !Task.isCancelled else { return }
            self?.flushStyleMemory()
        }
    }

    /// Writes the style memory now, if it changed since it was last written.
    func flushStyleMemory() {
        styleMemoryTask?.cancel()
        styleMemoryTask = nil
        let memory = model.styleMemory
        guard memory != savedStyleMemory else { return }
        savedStyleMemory = memory
        StyleMemoryStore.save(memory)
    }

    /// Writes a copy once the document has been still for a moment.
    ///
    /// Debounced rather than written per edit: a drag is dozens of committed changes, and
    /// re-encoding the base image PNG for each of them would make the editor stutter.
    private func scheduleAutosave(unsaved: Bool) {
        autosaveTask?.cancel()
        guard unsaved else {
            autosaveTask = nil
            if autosaveMayExist {
                autosave.discard(for: documentURL)
                autosaveMayExist = false
            }
            return
        }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.autosaveSettleMilliseconds))
            guard !Task.isCancelled else { return }
            self?.writeAutosave()
        }
    }

    /// Writes the recovery copy — off the main actor, unless the process is about to exit
    /// and a detached write would not get the chance to finish.
    func writeAutosave(synchronously: Bool = false) {
        let document = model.document
        let exportScale = Double(model.exportScale)
        let basePNG = basePNG
        let snapshotURL = documentURL
        let snapshotAutosave = autosave
        let snapshotLogger = logger
        autosaveMayExist = true
        let write: @Sendable () -> Void = {
            do {
                var contents = try basePNG.contents(for: document)
                contents.exportScale = exportScale
                try snapshotAutosave.write(contents, for: snapshotURL)
            } catch {
                snapshotLogger.error("Could not autosave: \(error.localizedDescription, privacy: .public)")
            }
        }
        if synchronously {
            write()
        } else {
            Task.detached(priority: .utility, operation: write)
        }
    }
}
