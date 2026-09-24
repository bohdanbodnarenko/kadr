import AVFoundation
import CoreMedia
import Foundation
import RecordingCore
import StudioSession
import Testing
@testable import Kadr

@MainActor
@Suite("Recording crash recovery")
struct RecordingCrashRecoveryTests {
    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kadr-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A playable leftover segment is restored to the save folder")
    func recoversAPlayableSegment() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let saves = root.appendingPathComponent("saves", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let abandoned = temporary.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try await writeMovie(to: abandoned.appendingPathComponent("segment-0.mp4"))

        var presented: [URL] = []
        let count = await RecordingCrashRecovery.recover(
            temporaryDirectory: temporary,
            inProgressDirectory: root.appendingPathComponent("in-progress", isDirectory: true),
            saveFolder: saves,
            sessions: RecordingSessionStore(root: sessions),
            present: { presented.append($0) }
        )

        #expect(count == 1)
        #expect(presented.count == 1)
        let movie = try #require(presented.first)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        #expect(movie.deletingLastPathComponent().standardizedFileURL == saves.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(!RecordingSessionStore(root: sessions).sessions().isEmpty)
    }

    /// A quit during setup leaves a folder with nothing recorded in it (docs/17 T-REC-10).
    @Test("A leftover folder with no footage is removed")
    func removesEmptyLeftovers() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let empty = temporary.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        let zeroByte = temporary.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zeroByte, withIntermediateDirectories: true)
        try Data().write(to: zeroByte.appendingPathComponent("segment-0.mp4"))

        let count = await RecordingCrashRecovery.recover(
            temporaryDirectory: temporary,
            inProgressDirectory: root.appendingPathComponent("in-progress", isDirectory: true),
            saveFolder: root,
            sessions: nil,
            present: { _ in }
        )

        #expect(count == 0)
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(!FileManager.default.fileExists(atPath: zeroByte.path))
    }

    @Test("Unreadable leftovers are left alone")
    func leavesUnreadableSegments() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let abandoned = temporary.appendingPathComponent(
            "\(InterruptedRecordingStore.directoryPrefix)dead",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("not a movie".utf8).write(to: abandoned.appendingPathComponent("segment-0.mp4"))

        let count = await RecordingCrashRecovery.recover(
            temporaryDirectory: temporary,
            inProgressDirectory: root.appendingPathComponent("in-progress", isDirectory: true),
            saveFolder: root.appendingPathComponent("saves", isDirectory: true),
            sessions: RecordingSessionStore(root: sessions),
            present: { _ in }
        )

        #expect(count == 0)
        #expect(FileManager.default.fileExists(atPath: abandoned.path))
    }

    @Test("A recording title keeps its movie extension")
    func libraryFilenameKeepsTheExtension() {
        #expect(
            HistoryView.libraryFilename(
                displayName: "Onboarding walkthrough",
                current: "Kadr Recording.mp4"
            ) == "Onboarding walkthrough.mp4"
        )
        #expect(
            HistoryView.libraryFilename(
                displayName: "Demo.mp4",
                current: "take.mp4"
            ) == "Demo.mp4"
        )
    }
}

private func writeMovie(to url: URL, frameCount: Int = 15, size: Int = 64) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size,
        AVVideoHeightKey: size
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for frame in 0 ..< frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adaptor.pixelBufferPool else { break }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { break }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, frame % 2 == 0 ? 0x30 : 0xC0, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? RecordingError.noFramesCaptured
    }
}
