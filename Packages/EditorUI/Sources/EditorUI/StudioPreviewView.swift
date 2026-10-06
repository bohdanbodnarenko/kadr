import AppKit
import AVFoundation
import ControlKit
import Foundation
import StudioRender
import StudioSession
import SwiftUI

/// The studio's picture (docs/09 U3.3).
///
/// Frames come from the same `StudioFrameComposer` the export uses, over the same
/// `StudioRenderPlan`. That is the entire reason the preview can be trusted: it is not
/// approximating what the export will do, it is doing it — inside an `AVPlayer`, through
/// `StudioVideoCompositor`, at whatever size the window happens to be.
///
/// Scrubbed *and* played (docs/08 §2 item 10). A zoom is a movement, a cut is a join and a
/// speed change is a rhythm, and none of the three can be judged from a frozen frame.
///
/// This view does no work of its own. It tells `StudioPlaybackController` what changed and
/// shows the player the controller owns; everything expensive happens off the main actor,
/// and nothing is built while the body is being evaluated.
@MainActor
struct StudioPreviewView: View {
    let model: StudioDocumentModel

    var body: some View {
        let playback = model.previewPlayback
        GeometryReader { geometry in
            let imageSize = previewImageSize(playback)
            let fitted = StudioCropGeometry.fittedImageRect(
                image: imageSize ?? model.manifest.pixelSize,
                in: geometry.size
            )
            ZStack {
                // A recessed well rather than a black rectangle butted against the window
                // edge: the picture is the thing being judged, and a surround that reads as
                // a surface tells the eye where it stops.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                StudioPreviewPlayerView(player: playback.player) { size, scale in
                    playback.setViewSize(size, backingScale: scale)
                }
                .accessibilityLabel(Text("Studio preview", bundle: .module))
                if playback.outputSize == nil {
                    ProgressView()
                        .controlSize(.small)
                }
                if !model.isPlaying {
                    StudioPreviewSkim(clock: model.playheadClock, playback: playback)
                }
                if model.isCropping {
                    StudioCropOverlay(model: model, fitted: fitted)
                } else if let id = model.aimingZoom {
                    StudioZoomTargetOverlay(model: model, id: id, fitted: fitted)
                } else if let imageSize, model.manifest.hasCamera, model.edit.camera.isVisible {
                    StudioCameraOverlay(
                        model: model,
                        fitted: fitted,
                        imageSize: imageSize
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .padding(10)
        }
        // The playhead and the hover are followed by a leaf that reads them, so a playback
        // tick re-evaluates that leaf and not this body (docs/11 S2).
        .background { StudioPreviewClockFollower(clock: model.playheadClock, playback: playback) }
        .onAppear { playback.update() }
        // One trigger per kind of change, each of which is cheap here: the controller
        // decides what, if anything, has to be rebuilt, and does it off the main actor.
        .onChange(of: model.edit) { playback.update() }
        .onChange(of: model.isCropping) { playback.update() }
        .onChange(of: model.isAimingZoom) { playback.update() }
        .onChange(of: model.transcript) { playback.update() }
    }

    /// The size of the picture the overlays are laid over: the whole recording while a
    /// crop is being placed, otherwise the built plan's output. Nil until one is built,
    /// which keeps the camera handles from appearing in the wrong place for a moment.
    private func previewImageSize(_ playback: StudioPlaybackController) -> CGSize? {
        model.isCropping ? model.manifest.pixelSize : playback.outputSize
    }
}

/// Tells the player where the playhead and the hover went.
///
/// Empty on purpose: it exists so that reading `StudioPlayhead` — which changes thirty
/// times a second while playing — invalidates this and nothing larger.
private struct StudioPreviewClockFollower: View {
    let clock: StudioPlayhead
    let playback: StudioPlaybackController

    var body: some View {
        Color.clear
            .onChange(of: clock.time) { _, time in playback.playheadDidChange(to: time) }
            .onChange(of: clock.hoverTime) { _, time in playback.skim(at: time) }
            .accessibilityHidden(true)
    }
}

/// The timeline hover thumbnail, pinned to the preview's top trailing corner.
private struct StudioPreviewSkim: View {
    let clock: StudioPlayhead
    let playback: StudioPlaybackController

    var body: some View {
        if let frame = playback.skimImage, clock.hoverTime != nil {
            VStack {
                HStack {
                    Spacer()
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: KadrRadius.medium, style: .continuous))
                        .shadow(radius: 8)
                        .padding(KadrSpace.large)
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .accessibilityLabel(Text("Timeline skim preview", bundle: .module))
        }
    }
}
