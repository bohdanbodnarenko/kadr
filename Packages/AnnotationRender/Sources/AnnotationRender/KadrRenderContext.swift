import CoreImage

/// The one CoreImage context the annotation renderer uses (docs/10 R2.6).
///
/// A `CIContext` compiles Metal pipelines on first use — tens of milliseconds and tens of
/// megabytes. Building one per redaction, per subject-lift, per blur and per camera tick
/// is how the editor ended up with four process-wide contexts. Shared, hardware-backed,
/// intermediates discarded so a long editing session cannot accumulate textures.
public enum KadrRenderContext {
    public static let shared = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
}
