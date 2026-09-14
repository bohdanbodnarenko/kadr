import Foundation

/// The service name the helper listens on. Prefixed by both host apps
/// (`app.kadr.Kadr` and `app.kadr.Kadr.Editor`) so the same XPC can live in
/// either bundle without rewriting its Info.plist after copy.
public enum VisionServiceName {
    public static let machServiceName = "app.kadr.Kadr.Editor.HelperTools"

    /// How long the helper stays alive with nothing to do (docs/04 §1).
    public static let idleTimeout: TimeInterval = 30
}
