import AnnotationModel
import CoreGraphics
import Foundation

public extension EditorDocumentModel {
    /// Native export size in pixels, after rotate/flip and before downscale.
    var nativeExportPixelSize: CGSize {
        document.orientation.orientedSize(of: document.baseImage.pixelSize)
    }

    /// Size Copy and Save will write, after the resize panel's scale (docs/03 §3 P2).
    var exportPixelSize: CGSize {
        CGSize(
            width: (nativeExportPixelSize.width * exportScale).rounded(),
            height: (nativeExportPixelSize.height * exportScale).rounded()
        )
    }

    var canScaleExportToOneToOne: Bool {
        document.baseImage.scale > 1 + .ulpOfOne
    }

    func resetExportScale() {
        exportScale = 1
    }

    func setExportScale(_ scale: CGFloat) {
        exportScale = scale
    }

    /// Halves a Retina capture on the way out, matching overlay Scale Retina.
    func scaleExportToOneToOne() {
        exportScale = 1 / max(document.baseImage.scale, 1)
    }

    func setExportPixelWidth(_ width: CGFloat) {
        let native = nativeExportPixelSize.width
        guard native > 0 else { return }
        exportScale = width / native
    }

    // MARK: - Export lifecycle (docs/14 UX-26)

    /// Marks an export as started, clearing whatever the previous one left behind.
    func beginExport(_ action: EditorExportAction) {
        exportFailure = nil
        runningExport = action
    }

    /// Marks an export as finished, however it finished.
    func endExport() {
        runningExport = nil
    }

    /// Reports an export that did not happen. The chrome offers Retry from here.
    func failExport(_ action: EditorExportAction, message: String) {
        runningExport = nil
        exportFailure = EditorExportFailure(action: action, message: message)
    }

    /// Whether the toolbar should show its progress chip and disable conflicting commands.
    var isExporting: Bool {
        runningExport != nil
    }

    /// Arms the copied toast after a pasteboard write succeeds (docs/14 UX-26).
    func requestCopyToast() {
        showsCopiedToast = true
    }

    /// Clears the toast flag once the chrome has shown it.
    func clearCopyToast() {
        showsCopiedToast = false
    }
}
