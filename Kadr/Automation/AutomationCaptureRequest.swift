import AppKit
import Foundation
import OverlayKit
import Shared

/// The automation request a capture is serving, if any (docs/03 §8.4).
///
/// Its own type rather than two properties on the coordinator, because the pair has an
/// invariant worth keeping in one place: overrides live for exactly one capture, and the
/// caller is told exactly once. A script blocked on `kadr capture-area` is waiting on the
/// "exactly once" half; a user taking the next screenshot by hand depends on the "exactly
/// one capture" half.
@MainActor
final class AutomationCaptureRequest {
    private(set) var overrides: CaptureOverrides = .none
    private var completion: ((CaptureOutcome) -> Void)?

    /// Arms the next capture. A previous request that never finished is told it was
    /// cancelled rather than left waiting.
    func arm(_ overrides: CaptureOverrides, completion: ((CaptureOutcome) -> Void)?) {
        report(.cancelled)
        self.overrides = overrides
        self.completion = completion
    }

    /// Reports an outcome to whoever armed the capture, once, and disarms.
    func report(_ outcome: CaptureOutcome) {
        guard let completion else { return }
        self.completion = nil
        overrides = .none
        completion(outcome)
    }
}

/// Finding the display a global rect lives on (CLAUDE.md rule 6).
enum DisplayLookup {
    /// The display a global rect overlaps most, or nil when it is off-screen.
    ///
    /// "Most" rather than "first": a selection never spans displays (docs/03 §1.1), so a
    /// rect that straddles two has to be resolved to one, and the one it mostly covers is
    /// the only defensible answer.
    static func display(containing rect: DisplayRect) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for screen in NSScreen.screens {
            guard let descriptor = ScreenDescriptor(screen) else { continue }
            let frame = DisplayRect(cgRect: CGDisplayBounds(descriptor.displayID))
            let overlap = frame.cgRect.intersection(rect.cgRect)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > (best?.area ?? 0) {
                best = (descriptor.displayID, area)
            }
        }
        return best?.id
    }

    /// Screens in CleanShot order: index 1 is the primary (menu-bar) display.
    static func orderedScreens() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap(ScreenDescriptor.init)
    }

    /// CleanShot §20: `display=1` is the primary display.
    static func screen(atOneBased index: Int) -> ScreenDescriptor? {
        let screens = orderedScreens()
        guard index >= 1, index <= screens.count else { return nil }
        return screens[index - 1]
    }

    /// Resolves a captured region and optional 1-based display index.
    ///
    /// Without `display`, `region` is already global AppKit screen space. With `display`,
    /// `region` is local to that display's bottom-left. An index the Mac does not have
    /// is a runtime failure — the parser cannot know how many screens are attached.
    static func resolve(region: ScreenRect?, display index: Int?) -> AutomationTarget {
        guard let index else {
            if let region {
                return .region(region)
            }
            return .interactive
        }
        let screens = orderedScreens()
        guard let screen = screen(atOneBased: index) else {
            return .failed("There is no display \(index) (this Mac has \(screens.count)).")
        }
        if let region {
            return .region(DisplayIndex.globalize(local: region, on: screen.frame))
        }
        return .display(screen.displayID)
    }
}

/// What automation asked to capture, after `display=` has been applied.
enum AutomationTarget {
    /// Open the interactive overlay (or the verb's default whole-target path).
    case interactive
    /// A rectangle in global AppKit screen space.
    case region(ScreenRect)
    /// One whole display, identified by CoreGraphics id.
    case display(CGDirectDisplayID)
    /// `display=` named a screen this Mac does not have.
    case failed(String)
}
