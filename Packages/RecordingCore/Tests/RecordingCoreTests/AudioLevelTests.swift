import Testing
@testable import RecordingCore

@Suite("Audio level")
struct AudioLevelTests {
    @Test("Silence is nothing, a full-scale sample is one")
    func peakOfSamples() {
        #expect(AudioLevel.peak(of: []) == 0)
        #expect(AudioLevel.peak(of: [0, 0, 0]) == 0)
        #expect(AudioLevel.peak(of: [0.2, -0.9, 0.1]) == 0.9)
        #expect(AudioLevel.peak(of: [2]) == 1)
        #expect(AudioLevel.peak(of: [-2]) == 1)
    }

    @Test("A meter treats a whisper as silence and a voice as not")
    func silenceThreshold() {
        #expect(AudioMeter(microphone: 0).microphoneIsSilent)
        #expect(AudioMeter(microphone: AudioMeter.silence / 2).microphoneIsSilent)
        #expect(!AudioMeter(microphone: 0.2).microphoneIsSilent)
        #expect(AudioMeter(microphone: 0.1, system: 0.8).peak == 0.8)
    }
}
