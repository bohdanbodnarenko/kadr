import Foundation

public extension AppCommand {
    /// What a request reaches beyond its verb — the file it reads, the region it captures,
    /// the microphone — for the consent prompt, so "Allow?" is answered knowing what for
    /// (docs/18 OUT-13). Empty when the verb says it all.
    var consentDetails: [String] {
        switch self {
        case let .captureArea(options), let .captureWindow(options), let .captureFullscreen(options),
             let .capturePreviousArea(options), let .captureText(options), let .captureScrolling(options),
             let .allInOne(options), let .selfTimer(options):
            var details: [String] = []
            if let path = options.path {
                details.append(String(localized: "Reads the file “\(Self.name(of: path))”"))
            }
            if let region = options.region {
                details
                    .append(
                        String(
                            localized: "A \(Int(region.width)) × \(Int(region.height)) pt region, no selection shown"
                        )
                    )
            }
            return details
        case let .recordScreen(options), let .recordRegion(options):
            var details: [String] = []
            if options.region != nil {
                details.append(String(localized: "Starts recording a region with no selection shown"))
            }
            if options.recordsMicrophone == true {
                details.append(String(localized: "Records the microphone"))
            }
            return details
        case let .pin(target?), let .annotate(target), let .addToHistory(target), let .addQuickAccessOverlay(target):
            return [String(localized: "Opens the file “\(Self.name(of: target.path))”")]
        default:
            return []
        }
    }

    private static func name(of path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).lastPathComponent
    }
}
