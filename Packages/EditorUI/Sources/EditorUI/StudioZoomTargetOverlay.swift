import StudioSession
import SwiftUI

/// Where a zoom points, placed on the picture itself (docs/09 U3.3).
///
/// The timeline says *when* a zoom happens and the lane says how long it holds, but until
/// now the only thing that said *where* was a 112-point map in the inspector — a second,
/// smaller copy of a picture already on screen. This draws the cue's frame on the real one:
/// everything outside it dims, because that is exactly what the zoom throws away.
///
/// Drag inside to aim, drag a corner to change the magnification, and a crosshair marks
/// where the pointer was when the zoom starts — the sample the automatic aim was taken
/// from, so the default is something the user can see rather than something that happened.
@MainActor
struct StudioZoomTargetOverlay: View {
    let model: StudioDocumentModel
    let id: ZoomCue.ID
    let fitted: CGRect

    @State private var isDraggingBody = false

    private let handleHitSize: CGFloat = 22

    var body: some View {
        if let cue = model.edit.zooms.first(where: { $0.id == id }) {
            let anchor = model.normalizedZoomAnchor(for: id)
            let target = StudioZoomTargetGeometry.viewport(
                anchor: anchor,
                magnification: cue.magnification,
                in: fitted
            )
            ZStack {
                dimmers(around: target)
                frame(target, magnification: cue.magnification)
                pointerMark
                body(target)
                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner, target: target, anchor: anchor)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Zoom target")
            .accessibilityValue(String(format: "%.1f×", cue.magnification))
        }
    }

    // MARK: - Pieces

    /// Everything the zoom leaves behind, dimmed — the same language as the crop overlay,
    /// because it is the same question: what stays in the frame?
    private func dimmers(around target: CGRect) -> some View {
        Canvas { context, size in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRoundedRect(in: target, cornerSize: CGSize(width: 4, height: 4))
            context.fill(outside, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private func frame(_ target: CGRect, magnification: Double) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(.white, lineWidth: 1.5)
            .frame(width: target.width, height: target.height)
            .position(x: target.midX, y: target.midY)
            .overlay {
                Text(String(format: "%.1f×", magnification))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: target.midX, y: max(target.minY - 14, 12))
            }
            .allowsHitTesting(false)
    }

    /// The pointer at the moment the zoom starts: the evidence behind the automatic aim.
    @ViewBuilder
    private var pointerMark: some View {
        if let pixel = model.pointerPixel(forZoom: id),
           let point = StudioZoomTargetGeometry.point(
               forPixel: pixel,
               in: model.manifest.pixelSize,
               fitted: fitted
           ) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(.white)
                    .frame(width: 4, height: 4)
            }
            .shadow(radius: 2)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .help("Where the pointer was when this zoom starts")
        }
    }

    private func body(_ target: CGRect) -> some View {
        Color.clear
            .frame(width: target.width, height: target.height)
            .position(x: target.midX, y: target.midY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDraggingBody = true
                        model.aimZoom(id, atNormalized: StudioZoomTargetGeometry.anchor(
                            at: value.location,
                            in: fitted
                        ))
                    }
                    .onEnded { _ in isDraggingBody = false }
            )
            .onHover { hovering in
                if hovering, !isDraggingBody {
                    NSCursor.openHand.set()
                } else if !hovering {
                    NSCursor.arrow.set()
                }
            }
            .help("Drag to aim this zoom. Drag a corner to change how close it goes.")
    }

    private func handle(_ corner: Corner, target: CGRect, anchor: CGPoint) -> some View {
        let point = corner.point(in: target)
        return Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .shadow(radius: 1)
            .frame(width: handleHitSize, height: handleHitSize)
            .contentShape(Rectangle())
            .position(x: point.x, y: point.y)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let zoom = StudioZoomTargetGeometry.magnification(
                            draggingCornerTo: value.location,
                            anchor: anchor,
                            in: fitted,
                            limit: 1 ... ZoomCue.maximumMagnification
                        )
                        model.updateZoom(id, coalescingAs: "zoom.magnification.\(id)") {
                            $0.magnification = zoom
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeading: CGPoint(x: rect.minX, y: rect.minY)
            case .topTrailing: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeading: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomTrailing: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }
}
