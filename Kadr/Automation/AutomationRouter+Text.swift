import AutomationKit
import Foundation
import SelectionUI
import Shared

extension AutomationRouter {
    /// OCR a file when `filepath=` is set; otherwise the TEXT overlay or a named region
    /// (CleanShot §20.6, docs/03 §1.7).
    func beginText(
        _ options: CaptureOptions,
        report: @escaping (CaptureOutcome) -> Void
    ) {
        if let path = options.path, !path.isEmpty {
            let url = FileTarget(path: path).url
            guard FileManager.default.fileExists(atPath: url.path) else {
                report(.failed("No image at \(url.path)."))
                return
            }
            areaCapture.recognizeFile(at: url)
            return
        }
        switch DisplayLookup.resolve(region: options.region, display: options.display) {
        case let .failed(message):
            report(.failed(message))
        case .interactive, .display:
            areaCapture.beginTextCapture()
        case let .region(rect):
            areaCapture.captureRegion(rect, purpose: .recognizeText)
        }
    }
}
