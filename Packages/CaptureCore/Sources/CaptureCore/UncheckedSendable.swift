/// Carries a value that is safe to hand to another task but is not marked `Sendable`.
///
/// ScreenCaptureKit's content objects — `SCDisplay`, `SCWindow`, `SCRunningApplication` —
/// are immutable descriptors handed out by `SCShareableContent`, but none of them carry
/// a `Sendable` conformance. Doc 04 §8 sanctions exactly this: SCK types cross isolation
/// boundaries through documented `@unchecked Sendable` wrappers.
///
/// The invariant this box relies on: **the wrapped value is only ever read.** Nothing in
/// Kadr mutates an SCK descriptor, so concurrent reads of one are safe.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

import ScreenCaptureKit

/// A prepared ScreenCaptureKit screenshot, ready to hand to the capture call.
///
/// `@unchecked Sendable` under a narrow invariant: a request is built, handed over
/// exactly once, and never read again by whoever built it. Every call site in
/// `CaptureEngine` reads what it needs off the filter *before* constructing the request,
/// which is what makes that true.
struct ScreenshotRequest: @unchecked Sendable {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
}
