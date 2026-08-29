import Foundation
import Testing
@testable import StudioCore

/// Following a reader through a script by what they say (docs/08, teleprompter).
///
/// Most of these test a *refusal*. Matching words when everything goes well is easy and
/// nearly untestable — the interesting behaviour is what happens when the recogniser is
/// wrong, the reader skips a line, or the script says "the" for the ninetieth time, and in
/// every one of those cases the right answer is usually to stay put.
@Suite("Speech follower")
struct SpeechFollowerTests {
    private let script = TeleprompterScript(text: """
    Welcome to Kadr, the screen recorder that stays out of your way.
    Press the shortcut and drag a region, and the capture appears as a card.
    Everything you need is in that card, and nothing you do not.
    """)

    private func words(_ sentence: String) -> [String] {
        sentence.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Following

    @Test("Reading the opening moves the position into the script")
    func followsTheOpening() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("welcome to kadr the screen"),
            in: script,
            from: 0
        )
        #expect(position >= 4, "the reader is five words in, not at the start")
        #expect(position <= 7)
    }

    @Test("Reading on advances further")
    func advances() {
        let follower = SpeechFollower()
        let first = follower.position(heard: words("welcome to kadr the screen"), in: script, from: 0)
        let second = follower.position(
            heard: words("recorder that stays out of your way"),
            in: script,
            from: first
        )
        #expect(second > first)
    }

    /// A recogniser hears "cadre" for "Kadr" and "grab" for "drag". Enough of the phrase
    /// still agrees, so the reader is followed rather than abandoned over a proper noun.
    @Test("A misheard word does not stop the follow")
    func toleratesMisrecognition() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("welcome to cadre the screen recorder"),
            in: script,
            from: 0
        )
        #expect(position > 3, "one wrong word threw away an otherwise good match")
    }

    @Test("A skipped word does not stop the follow")
    func toleratesSkipping() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("welcome to kadr screen recorder"),
            in: script,
            from: 0
        )
        #expect(position > 3)
    }

    // MARK: - Refusals

    /// The failure that makes a prompter unusable. "the" appears throughout the script, and
    /// a follower that moves on one word lands wherever it likes.
    @Test("A single common word moves nothing")
    func singleWordIsNotEvidence() {
        let follower = SpeechFollower()
        #expect(follower.position(heard: ["the"], in: script, from: 10) == 10)
        #expect(follower.position(heard: ["and"], in: script, from: 10) == 10)
    }

    @Test("Two words are not enough either")
    func twoWordsAreNotEnough() {
        let follower = SpeechFollower()
        #expect(follower.position(heard: words("in that"), in: script, from: 20) == 20)
    }

    /// Somebody who stops reading the script and starts explaining should find the prompter
    /// where they left it, not scrolled to wherever their words happened to land.
    @Test("Going off script holds the position")
    func offScriptHolds() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("so anyway let me tell you about something else entirely"),
            in: script,
            from: 12
        )
        #expect(position == 12)
    }

    @Test("Silence holds the position")
    func silenceHolds() {
        let follower = SpeechFollower()
        #expect(follower.position(heard: [], in: script, from: 7) == 7)
    }

    @Test("Punctuation-only noise holds the position")
    func noiseHolds() {
        let follower = SpeechFollower()
        #expect(follower.position(heard: ["...", ",", "—"], in: script, from: 7) == 7)
    }

    /// Travelling back up the page because a recogniser produced an early word is the other
    /// way to make a prompter unreadable.
    @Test("The position never falls far behind where it was")
    func neverJumpsBackwards() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("welcome to kadr the screen recorder"),
            in: script,
            from: 25
        )
        #expect(position >= 25 - follower.lookbehind)
    }

    /// A phrase that reappears later must not pull the reader forwards. The follower looks
    /// only a little way ahead for exactly this reason.
    @Test("A phrase repeated later in the script does not pull the reader to it")
    func repeatedPhraseDoesNotTeleport() {
        let repetitive = TeleprompterScript(text: """
        press the shortcut and drag a region
        \(String(repeating: "filler words to push things apart ", count: 20))
        press the shortcut and drag a region
        """)
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("press the shortcut and drag"),
            in: repetitive,
            from: 0
        )
        #expect(position < 20, "the follower jumped to the later copy, \(position) words in")
    }

    // MARK: - Edges

    @Test("An empty script follows nothing")
    func emptyScript() {
        let follower = SpeechFollower()
        #expect(follower.position(heard: words("anything at all"), in: TeleprompterScript(text: ""), from: 3) == 0)
    }

    @Test("The position never runs past the end of the script")
    func staysInsideTheScript() {
        let follower = SpeechFollower()
        let position = follower.position(
            heard: words("everything you need is in that card and nothing you do not"),
            in: script,
            from: script.words.count - 6
        )
        #expect(position <= script.words.count)
    }

    @Test("A position already past the end does not crash or move")
    func pastTheEnd() {
        let follower = SpeechFollower()
        let beyond = script.words.count + 10
        #expect(follower.position(heard: words("welcome to kadr"), in: script, from: beyond) == beyond)
    }

    /// Only the tail is used, so a caller can pass the whole transcript so far without the
    /// follow getting slower or less accurate as the recording goes on.
    @Test("Only the most recent words matter")
    func onlyTheTailMatters() {
        let follower = SpeechFollower()
        let short = follower.position(heard: words("press the shortcut and drag"), in: script, from: 8)
        let long = follower.position(
            heard: words("welcome to kadr the screen recorder that stays out of your way press the shortcut and drag"),
            in: script,
            from: 8
        )
        #expect(short == long)
    }

    // MARK: - A whole reading

    /// The end-to-end shape: read the script in overlapping chunks and the position should
    /// climb steadily to the end without ever going backwards.
    @Test("Reading the script through follows it to the end")
    func readsThrough() {
        let follower = SpeechFollower()
        let spoken = script.words.map(\.normalized)
        var position = 0
        var previous = 0

        for end in stride(from: 3, through: spoken.count, by: 3) {
            position = follower.position(heard: Array(spoken[..<end]), in: script, from: position)
            #expect(position >= previous - follower.lookbehind, "the follow went backwards at word \(end)")
            previous = position
        }
        #expect(position > script.words.count - 8, "the follow finished \(position) of \(script.words.count) in")
    }
}
