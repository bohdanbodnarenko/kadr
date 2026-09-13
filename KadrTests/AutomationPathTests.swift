import AppKit
import CaptureCore
import Foundation
import MediaExport
import SettingsKit
import Shared
import Testing
@testable import Kadr

/// Automation naming files by path (docs/03 §8.4, docs/07 M11, docs/09 U0.5).
///
/// `kadr pin --path …` and `kadr annotate --path …` take a path rather than a card, so they
/// skipped the finalise-on-first-action step that every card action performs. A pin left
/// on a staged capture went blank when the 24-hour staging sweep ran — the pin was still
/// on screen, its file was in the Trash.
@MainActor
@Suite("Automation by path", .serialized)
struct AutomationPathTests {
    /// A harness holding one staged capture, and the folders it can move between.
    private struct StagedCapture {
        let harness: TestHarness
        let save: URL
        let stage: URL
        /// The staged file, as automation would name it.
        let url: URL
    }

    private func stagedCapture(pins: PinManager = ephemeralPinManager()) throws -> StagedCapture {
        let save = temporaryDirectory("save")
        let stage = temporaryDirectory("stage")
        let harness = makeManager(saveFolder: save, stagingFolder: stage, pins: pins)
        harness.settings.defaultAction = .overlayOnly

        let capture = makeCapture()
        let result = try #require(harness.output.deliver(capture))
        return try StagedCapture(harness: harness, save: save, stage: stage, url: #require(result.fileURL))
    }

    @Test("Pinning a staged path moves the file out of staging first")
    func pinFinalisesStagedPath() throws {
        let pins = ephemeralPinManager()
        let staged = try stagedCapture(pins: pins)
        let (harness, save, stage, url) = (staged.harness, staged.save, staged.stage, staged.url)
        defer { pins.closeAll() }

        #expect(harness.output.isStaged(url))
        #expect(harness.manager.pinFile(at: url))

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty,
            "a pin over a staged file is a pin the sweep will empty"
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 1)
    }

    @Test("The pin ends up pointing at the file's new home")
    func pinFollowsTheFinalisedFile() throws {
        let pins = ephemeralPinManager()
        let staged = try stagedCapture(pins: pins)
        let (harness, save, url) = (staged.harness, staged.save, staged.url)
        defer { pins.closeAll() }

        #expect(harness.manager.pinFile(at: url))
        let moved = save.appendingPathComponent(url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A path that was never staged is pinned exactly as given")
    func ordinaryPathIsUntouched() throws {
        let pins = ephemeralPinManager()
        let session = try stagedCapture(pins: pins)
        let (harness, staged) = (session.harness, session.url)
        defer { pins.closeAll() }

        let elsewhere = temporaryDirectory("elsewhere").appendingPathComponent("shot.png")
        try FileManager.default.copyItem(at: staged, to: elsewhere)

        #expect(!harness.output.isStaged(elsewhere))
        #expect(harness.manager.pinFile(at: elsewhere))
        #expect(FileManager.default.fileExists(atPath: elsewhere.path), "nothing should have moved it")
    }

    @Test("A path that does not exist is refused rather than pinned blank")
    func missingPathIsRefused() throws {
        let harness = try stagedCapture().harness
        let missing = temporaryDirectory("gone").appendingPathComponent("nothing.png")
        #expect(!harness.manager.pinFile(at: missing))
    }

    /// The same hole, on the other automation verb: the editor must not be handed a path
    /// the sweep can delete while the user is drawing on it.
    @Test("Annotating a staged path finalises it too")
    func annotateFinalisesStagedPath() throws {
        let staged = try stagedCapture()
        let (harness, save, stage, url) = (staged.harness, staged.save, staged.stage, staged.url)

        harness.manager.annotateFile(at: url)

        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: save.path).count == 1)
    }
}
