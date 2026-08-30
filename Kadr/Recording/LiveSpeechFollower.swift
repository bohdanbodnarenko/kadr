import Foundation
import os
import Shared
import StudioSession

/// Listens while somebody reads, and says where in the script they are (docs/08).
///
/// Live recognition used to run `SFSpeechRecognizer` and an `AVAudioEngine` tap inside
/// the resident agent for the length of a recording. That is the RAM shape docs/04 §7.4
/// says must die with a helper, and it is what put Speech.framework in every launch of a
/// user who never records (docs/10 R2.1). Following is therefore unavailable in the agent:
/// the prompter scrolls at the rate the user set, which is the documented fallback when
/// there is no model, no permission, or no microphone.
///
/// The matcher itself (`SpeechFollower`) is still here and still tested — moving the
/// microphone behind XPC is a later decision (docs/10), not a reason to throw away the
/// part that does not need one.
@MainActor
final class LiveSpeechFollower {
    private let logger = KadrLog.logger(.recording)
    private let script: TeleprompterScript
    private let follower = SpeechFollower()

    /// Where the reader appears to be, or nil until something has been heard.
    private(set) var position: Int?

    init(script: TeleprompterScript) {
        self.script = script
    }

    /// Starts listening. Returns false when it cannot, which is not an error.
    func start() async -> Bool {
        guard !script.isEmpty else { return false }
        logger.info("Speech following is not in the agent; the prompter will scroll at a steady rate")
        return false
    }

    func stop() {
        position = nil
    }

    /// Advances from recognised words, for tests that have no microphone.
    func advanceForTesting(heard: [String]) {
        position = follower.position(heard: heard, in: script, from: position ?? 0)
    }
}
