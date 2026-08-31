import Foundation

/// Subtitle cues from a timed transcript (docs/13 T2.2).
public struct CaptionCue: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// The word currently being said, for karaoke highlighting.
    public var highlight: String?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        highlight: String? = nil
    ) {
        self.id = id
        self.start = max(start, 0)
        self.end = max(end, self.start)
        self.text = text
        self.highlight = highlight
    }
}

/// Groups words into caption cues and writes SRT / VTT.
///
/// Times are *edited* time: the transcript is in source time, and a caption that ignores
/// cuts would show words the user already removed.
public enum CaptionExport {
    /// About one spoken sentence, or three seconds, whichever comes first.
    public static let maximumCueDuration: TimeInterval = 3.2

    public static func cues(
        from transcript: Transcript,
        timeline: ClipTimeline,
        at time: TimeInterval? = nil
    ) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var buffer: [TranscriptWord] = []
        var cueStart: TimeInterval?

        func flush() {
            guard let start = cueStart, !buffer.isEmpty else { return }
            let texts = buffer.map(\.text)
            let end = buffer.last.flatMap { timeline.editedTime(forSource: $0.end) } ?? start
            var highlight: String?
            if let time {
                highlight = buffer.first { word in
                    guard let wordStart = timeline.editedTime(forSource: word.start),
                          let wordEnd = timeline.editedTime(forSource: word.end)
                    else { return false }
                    return time >= wordStart && time < wordEnd
                }?.text
            }
            cues.append(CaptionCue(
                start: start,
                end: max(end, start + 0.4),
                text: texts.joined(separator: " "),
                highlight: highlight
            ))
            buffer = []
            cueStart = nil
        }

        for word in transcript.words {
            guard let editedStart = timeline.editedTime(forSource: word.start) else { continue }
            if let start = cueStart {
                let spanned = editedStart - start
                let endsSentence = Self.endsSentence(word.text)
                if spanned >= maximumCueDuration || endsSentence && spanned > 0.6 {
                    if endsSentence {
                        buffer.append(word)
                    }
                    flush()
                    if endsSentence {
                        continue
                    }
                }
            }
            if cueStart == nil {
                cueStart = editedStart
            }
            buffer.append(word)
        }
        flush()
        return cues
    }

    public static func cue(
        from transcript: Transcript,
        timeline: ClipTimeline,
        at time: TimeInterval
    ) -> CaptionCue? {
        cues(from: transcript, timeline: timeline, at: time).first { time >= $0.start && time < $0.end }
    }

    public static func srt(from transcript: Transcript, timeline: ClipTimeline) -> String {
        let cues = cues(from: transcript, timeline: timeline)
        return cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))
            \(cue.text)
            """
        }
        .joined(separator: "\n\n")
        .appending(cues.isEmpty ? "" : "\n")
    }

    public static func vtt(from transcript: Transcript, timeline: ClipTimeline) -> String {
        let body = cues(from: transcript, timeline: timeline).map { cue in
            "\(Self.vttTime(cue.start)) --> \(Self.vttTime(cue.end))\n\(cue.text)"
        }
        .joined(separator: "\n\n")
        return "WEBVTT\n\n" + body + (body.isEmpty ? "" : "\n")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?。！？".contains(last)
    }

    private static func srtTime(_ time: TimeInterval) -> String {
        clock(time, fractionSeparator: ",")
    }

    private static func vttTime(_ time: TimeInterval) -> String {
        clock(time, fractionSeparator: ".")
    }

    private static func clock(_ time: TimeInterval, fractionSeparator: String) -> String {
        let total = max(time, 0)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        let millis = Int((total.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(
            format: "%02d:%02d:%02d\(fractionSeparator)%03d",
            hours,
            minutes,
            seconds,
            millis
        )
    }
}

/// Chapter marks from long pauses and sentence boundaries (docs/13 T2.5).
public struct ChapterMark: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var time: TimeInterval
    public var title: String

    public init(id: UUID = UUID(), time: TimeInterval, title: String) {
        self.id = id
        self.time = max(time, 0)
        self.title = title
    }
}

public enum ChapterMarks {
    public static let pauseThreshold: TimeInterval = 2.5

    public static func marks(from transcript: Transcript, duration: TimeInterval) -> [ChapterMark] {
        guard !transcript.words.isEmpty else { return [] }
        var marks: [ChapterMark] = [ChapterMark(time: 0, title: "Start")]
        var previousEnd: TimeInterval = 0
        var sentence = ""

        for word in transcript.words {
            let gap = word.start - previousEnd
            let endsSentence = word.text.last.map { ".!?。！？".contains($0) } ?? false
            if word.start > 1, gap >= pauseThreshold || (endsSentence && gap >= 1.1) {
                let title = sentence.isEmpty ? Self.title(at: word.start) : String(sentence.prefix(48))
                marks.append(ChapterMark(time: word.start, title: title.trimmingCharacters(in: .whitespaces)))
                sentence = ""
            }
            sentence += (sentence.isEmpty ? "" : " ") + word.text
            previousEnd = max(previousEnd, word.end)
        }
        return Self.deduped(marks, duration: duration)
    }

    private static func title(at time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func deduped(_ marks: [ChapterMark], duration: TimeInterval) -> [ChapterMark] {
        var kept: [ChapterMark] = []
        for mark in marks where mark.time < duration {
            if let last = kept.last, mark.time - last.time < 4 {
                continue
            }
            kept.append(mark)
        }
        return kept
    }
}
