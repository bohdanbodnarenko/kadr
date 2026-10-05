import StudioSession
import SwiftUI

/// What a zoom block says about itself: how it aims, how far in, and a way to remove it.
///
/// Its own view so each block tracks its own hover; the × appears only under the pointer,
/// because a lane of permanent delete buttons invites the wrong click while dragging.
struct StudioZoomBlockLabel: View {
    let cue: ZoomCue
    let focus: StudioZoomFocus
    let showsDetail: Bool
    /// Hides the hover chrome while the block is being dragged or resized.
    let isDragging: Bool
    let remove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            if showsDetail {
                Image(systemName: focus.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(StudioMultiplier.text(cue.magnification))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if showsDetail {
                // Always laid out, only faded: a button that appears and disappears pushes
                // the label sideways, and during a drag the pointer crosses it constantly.
                let visible = isHovering && !isDragging
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .animation(.easeOut(duration: 0.12), value: visible)
                .help(Text("Remove this zoom", bundle: .module))
                .accessibilityLabel(Text("Remove zoom", bundle: .module))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        // A plain state change: wrapping it in `withAnimation` animated whatever else
        // changed in the same update — including the block's own width mid-resize.
        .onHover { isHovering = $0 }
    }
}

/// A suggested zoom: an outline in the zoom colour with a plus, so it reads as "not yet".
struct StudioZoomSuggestionLabel: View {
    let width: CGFloat
    let height: CGFloat

    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange.opacity(isHovering ? 0.22 : 0.08))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    Color.orange.opacity(isHovering ? 0.9 : 0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            if width >= 22 {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.orange.opacity(isHovering ? 1 : 0.7))
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

/// Where a click on the empty zoom lane would add a zoom, drawn under the pointer.
///
/// A leaf that reads the hover clock itself, so following the pointer re-renders this and
/// not the lane. Nothing is drawn where a click would not add anything — inside a zoom, in a
/// gap too small, or over a suggestion that has its own outline.
struct StudioZoomAddGhost: View {
    let model: StudioDocumentModel
    let clock: StudioPlayhead
    let scale: CGFloat
    let height: CGFloat
    let avoiding: [ClosedRange<TimeInterval>]

    var body: some View {
        if let time = clock.hoverTime,
           !avoiding.contains(where: { $0.contains(time) }),
           let span = model.zoomPlacement(at: time) {
            let width = (span.high - span.low) * scale
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(0.14))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.orange.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                if width >= 58 {
                    Label(String(localized: "Add zoom", bundle: .module), systemImage: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else if width >= 16 {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
            }
            .frame(width: max(width, 4), height: height)
            .offset(x: span.low * scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The names of the timeline's lanes, beside them, with a way to add to the zoom lane.
///
/// Editing apps label their tracks; without that the zoom lane was an unexplained orange
/// strip, and adding a zoom by hand was something people only found by accident.
struct StudioTimelineTrackHeaders: View {
    let model: StudioDocumentModel
    let topInset: CGFloat
    let cueHeight: CGFloat
    let laneSpacing: CGFloat
    let clipHeight: CGFloat

    static let width: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: laneSpacing) {
            HStack(spacing: 2) {
                Text("Zoom", bundle: .module)
                Spacer(minLength: 0)
                Button {
                    model.pausePlayback()
                    model.addOrSelectZoom(at: model.playhead)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("Add a zoom at the playhead (Z at the pointer)", bundle: .module))
                .accessibilityLabel(Text("Add zoom at playhead", bundle: .module))
            }
            .frame(height: cueHeight)
            Text("Clips", bundle: .module)
                .frame(height: clipHeight, alignment: .center)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, topInset)
        .padding(.trailing, 8)
        .frame(width: Self.width, alignment: .topLeading)
    }
}

extension StudioZoomFocus {
    /// The glyph a zoom block wears for its aim.
    var symbol: String {
        switch self {
        case .pointer: "cursorarrow.motionlines"
        case .fixed: "scope"
        case .centre: "circle.circle"
        }
    }
}
