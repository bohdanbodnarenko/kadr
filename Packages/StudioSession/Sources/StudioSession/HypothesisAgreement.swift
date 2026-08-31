import Foundation
import Shared

/// How many consecutive hypotheses a word must survive before the prompter moves
/// (docs/13 T2.1).
///
/// Live recognition rewrites itself. Advancing on every partial would jump the script
/// backwards the moment a word was retracted, which is worse than not following at all.
/// Two consecutive hypotheses agreeing is enough evidence to move forward and never back.
public struct HypothesisAgreement: Sendable {
    private var previous: [String] = []

    public init() {}

    /// Words that appeared, in order, in both this hypothesis and the last one.
    public mutating func confirmed(from hypothesis: [String]) -> [String] {
        let normalized = hypothesis
            .map(TeleprompterScript.normalize)
            .filter { !$0.isEmpty }
        let agreed = zip(previous, normalized).prefix { $0 == $1 }.map(\.0)
        previous = normalized
        return agreed
    }
}
