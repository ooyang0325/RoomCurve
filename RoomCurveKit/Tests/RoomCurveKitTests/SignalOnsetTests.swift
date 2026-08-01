import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Signal onset")
struct SignalOnsetTests {
    let sampleRate = 48_000.0

    /// Quiet room noise for `seconds`, then a signal.
    func recording(silence seconds: Double, thenSignal signalSeconds: Double,
                   noise: Float = 0.002, level: Float = 0.2) -> (samples: [Float], onset: Int) {
        var rng = SystemRandomNumberGenerator()
        let quiet = Int(seconds * sampleRate)
        let loud = Int(signalSeconds * sampleRate)
        var out = [Float](repeating: 0, count: quiet + loud)
        for i in 0..<out.count {
            out[i] = Float.random(in: -noise...noise, using: &rng)
            if i >= quiet {
                out[i] += level * Float(sin(2 * Double.pi * 3_000 * Double(i) / sampleRate))
            }
        }
        return (out, quiet)
    }

    @Test("finds the start of the signal")
    func findsOnset() throws {
        let (samples, onset) = recording(silence: 2.0, thenSignal: 1.0)
        let found = try #require(SignalOnset.find(in: samples, sampleRate: sampleRate))
        #expect(abs(found - onset) < Int(0.05 * sampleRate))
    }

    @Test("waits patiently through a long silence")
    func longSilence() throws {
        // The whole point: somebody has to walk to a laptop and press play.
        let (samples, onset) = recording(silence: 45.0, thenSignal: 1.0)
        let found = try #require(SignalOnset.find(in: samples, sampleRate: sampleRate))
        #expect(abs(found - onset) < Int(0.05 * sampleRate))
    }

    @Test("reports nothing while the room is merely quiet")
    func noSignalYet() {
        var rng = SystemRandomNumberGenerator()
        let quiet = (0..<Int(5 * sampleRate)).map { _ in
            Float.random(in: -0.002...0.002, using: &rng)
        }
        #expect(SignalOnset.find(in: quiet, sampleRate: sampleRate) == nil)
    }

    @Test("is not fooled by digital silence")
    func digitalSilence() {
        // With a zero noise floor every block technically exceeds it.
        let silent = [Float](repeating: 0, count: Int(3 * sampleRate))
        #expect(SignalOnset.find(in: silent, sampleRate: sampleRate) == nil)
    }

    @Test("survives a click during the reference window")
    func toleratesAClick() throws {
        var (samples, onset) = recording(silence: 2.0, thenSignal: 1.0)
        // A door closing early on would drag a mean-based floor up and hide the signal.
        for i in 4_800..<5_000 { samples[i] = 0.5 }
        let found = try #require(SignalOnset.find(in: samples, sampleRate: sampleRate))
        #expect(abs(found - onset) < Int(0.05 * sampleRate))
    }

    @Test("needs enough audio before it will answer")
    func tooShort() {
        #expect(SignalOnset.find(in: [Float](repeating: 0.1, count: 100),
                                 sampleRate: sampleRate) == nil)
    }

    @Test("finds a quiet signal in a quiet room")
    func quietSignal() throws {
        let (samples, onset) = recording(silence: 3.0, thenSignal: 1.0,
                                         noise: 0.0005, level: 0.01)
        let found = try #require(SignalOnset.find(in: samples, sampleRate: sampleRate))
        #expect(abs(found - onset) < Int(0.05 * sampleRate))
    }

    @Test("knows how much more audio a complete measurement needs")
    func remainingSamples() {
        let config = SweepConfig(duration: 3, sampleRate: 48_000, preRoll: 2.5,
                                 gap: 0.5, tail: 1.0)
        let stimulus = SweepGenerator.make(config)
        let needed = stimulus.samplesNeededAfterOnset
        // Everything from the chirp to the end of the file, plus a margin of quiet after it
        // that doubles as the noise reference.
        #expect(needed > stimulus.samples.count - Int(config.preRoll * 48_000))
        #expect(needed < stimulus.samples.count + Int(2 * 48_000))
    }

    @Test("a real stimulus is detected at its chirp")
    func detectsRealStimulus() throws {
        let config = SweepConfig(duration: 1.0, sampleRate: 48_000, preRoll: 0.5,
                                 gap: 0.2, tail: 0.3)
        let stimulus = SweepGenerator.make(config)

        var rng = SystemRandomNumberGenerator()
        var samples = (0..<Int(6 * 48_000)).map { _ in
            Float.random(in: -0.001...0.001, using: &rng)
        }
        let start = Int(4 * 48_000)
        for (i, value) in stimulus.samples.enumerated() where start + i < samples.count {
            samples[start + i] += value * 0.3
        }

        let found = try #require(SignalOnset.find(in: samples, sampleRate: 48_000))
        // Detection lands on the chirp, which is preRoll into the file.
        let expected = start + stimulus.chirpStart
        #expect(abs(found - expected) < Int(0.05 * 48_000))
    }
}
