import AppKit
import XCTest

/// The editor, launched for real on a fixture image (docs/18 UX-02).
///
/// UI tests drive the app through the accessibility API, so they need a logged-in session
/// with the test runner allowed under Accessibility. That is why they run through
/// `make test-ui` only, never `make test` or CI. The editor is the target because it needs
/// no Screen Recording grant: everything here works on a file.
final class EditorSmokeUITests: XCTestCase {
    private var fixture = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KadrUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = folder.appendingPathComponent("Fixture.png")
        try Self.writeFixture(to: fixture)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
    }

    @MainActor
    private func launchEditor() -> XCUIApplication {
        let app = XCUIApplication()
        // KadrUITesting skips the restoration and recovery prompts, which would otherwise
        // depend on this Mac, and opens the fixture named in the environment instead.
        app.launchArguments = ["-KadrUITesting", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["KADR_UI_TEST_DOCUMENT"] = fixture.path
        app.launch()
        return app
    }

    @MainActor
    func testOpensAFixtureWithItsControls() {
        let app = launchEditor()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "the editor opened no window for the fixture")
        XCTAssertTrue(app.descendants(matching: .any)["editor.canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor.copy"].exists)
        XCTAssertTrue(app.buttons["editor.save"].exists)
    }

    @MainActor
    func testPassesTheAccessibilityAudit() throws {
        let app = launchEditor()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // Contrast and clipped-text findings depend on the display and the wallpaper
        // behind translucent chrome, so they are reported by the manual audit instead.
        let audits: XCUIAccessibilityAuditType = [.elementDetection, .sufficientElementDescription, .hitRegion]
        try app.performAccessibilityAudit(for: audits) { issue in
            // The one known exception: the split containers AppKit builds for SwiftUI's
            // `.inspector` are unnamed groups no modifier can reach. Anything else fails.
            if let element = issue.element, Self.isInspectorSplitContainer(element) {
                return true
            }
            // The audit covers the whole app; the menu bar is AppKit's, so only the
            // editor window's own content is judged here.
            if let element = issue.element, !app.windows.firstMatch.frame.contains(element.frame) {
                return true
            }
            // The title bar's document proxy icon is AppKit's, labelled with the file name.
            if let element = issue.element, Self.isTitleBarProxy(element, in: app.windows.firstMatch) {
                return true
            }
            let element = issue.element.map { "\($0.elementType) '\($0.identifier)' \($0.frame)" } ?? "no element"
            print("Accessibility audit: \(issue.compactDescription) — \(element)")
            return false
        }
    }

    /// A small image in the window's title bar: the document proxy icon.
    @MainActor
    private static func isTitleBarProxy(_ element: XCUIElement, in window: XCUIElement) -> Bool {
        let titleBarHeight: CGFloat = 32
        return element.elementType == .image
            && element.frame.height <= 24
            && element.frame.minY < window.frame.minY + titleBarHeight
    }

    /// An unnamed group wrapping the canvas or the inspector: one of the split containers
    /// AppKit builds for `.inspector`.
    @MainActor
    private static func isInspectorSplitContainer(_ element: XCUIElement) -> Bool {
        guard element.elementType == .group, element.label.isEmpty, element.identifier.isEmpty else {
            return false
        }
        let inside = element.descendants(matching: .any)
        return inside["editor.canvas"].exists || inside["editor.inspector"].exists
    }

    private static func writeFixture(to url: URL) throws {
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSRect(x: 80, y: 80, width: 320, height: 160).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
