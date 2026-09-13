import AnnotationModel
import SettingsKit

/// Maps the capture-pane auto-beautify setting onto a spec the editor understands.
enum AutoBeautify {
    static func spec(for preset: AutoBeautifyPreset) -> BeautifySpec? {
        switch preset {
        case .off: nil
        case .cleanWhite: .cleanWhite
        case .twitter: .twitter
        case .instagram: .instagram
        case .story: .story
        case .stuckBottom: .stuckBottom
        }
    }
}
