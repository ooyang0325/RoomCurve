import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Chirp detection")
struct ChirpDetectorTests {
    let sampleRate = 48_000.0
    var chirp: [Float] { SweepGenerator.makeChirp(sampleRate: 48_000) }

    func detector() -> ChirpDetector {
        ChirpDetector(reference: chirp, sampleRate: sampleRate)
    }

    /// Room tone for `seconds`, then whatever `content` is, then more room tone.
    func recording(silence seconds: Double, then content: [Float],
                   noise: Float = 0.002, tail: Double = 3.0) -> (samples: [Float], at: Int) {
        var rng = SystemRandomNumberGenerator()
        let quiet = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: quiet + content.count + Int(tail * sampleRate))
        for i in out.indices { out[i] = Float.random(in: -noise...noise, using: &rng) }
        for (i, value) in content.enumerated() { out[quiet + i] += value }
        return (out, quiet)
    }

    @Test("finds the chirp")
    func findsChirp() throws {
        let (samples, at) = recording(silence: 2.0, then: chirp.map { $0 * 0.3 })
        let found = try #require(detector().scan(samples))
        #expect(abs(found - at) < Int(0.02 * sampleRate))
    }

    @Test("waits through a long silence")
    func longWait() throws {
        let (samples, at) = recording(silence: 40.0, then: chirp.map { $0 * 0.3 })
        let found = try #require(detector().scan(samples))
        #expect(abs(found - at) < Int(0.02 * sampleRate))
    }

    // MARK: - The things that used to trigger it

    @Test("ignores a loud burst of broadband noise")
    func ignoresNoiseBurst() {
        // Somebody talking, a chair scraping, traffic. Far louder than the room, and under the
        // old energy test this started a capture.
        var rng = SystemRandomNumberGenerator()
        let burst = (0..<Int(0.4 * sampleRate)).map { _ in
            Float.random(in: -0.5...0.5, using: &rng)
        }
        let (samples, _) = recording(silence: 2.0, then: burst)
        #expect(detector().scan(samples) == nil)
    }

    @Test("ignores an impulse")
    func ignoresClick() {
        // A door closing. Its spectrum is flat, so matched filtering spreads it across the
        // whole chirp length instead of concentrating it into a peak.
        var click = [Float](repeating: 0, count: Int(0.4 * sampleRate))
        click[100] = 1.0
        click[101] = -0.8
        let (samples, _) = recording(silence: 2.0, then: click)
        #expect(detector().scan(samples) == nil)
    }

    @Test("ignores a steady tone")
    func ignoresTone() {
        let tone = (0..<Int(1.0 * sampleRate)).map {
            Float(0.4 * sin(2 * Double.pi * 4_000 * Double($0) / 48_000))
        }
        let (samples, _) = recording(silence: 2.0, then: tone)
        #expect(detector().scan(samples) == nil)
    }

    @Test("ignores music-like content")
    func ignoresMusic() {
        // A handful of harmonically related tones with an envelope.
        var rng = SystemRandomNumberGenerator()
        let n = Int(2.0 * sampleRate)
        let music = (0..<n).map { i -> Float in
            let t = Double(i) / 48_000
            let envelope = 0.5 * (1 - cos(2 * Double.pi * 2 * t))
            var value = 0.0
            for harmonic in 1...6 {
                value += sin(2 * Double.pi * 220 * Double(harmonic) * t) / Double(harmonic)
            }
            return Float(value * envelope * 0.2) + Float.random(in: -0.01...0.01, using: &rng)
        }
        let (samples, _) = recording(silence: 2.0, then: music)
        #expect(detector().scan(samples) == nil)
    }

    @Test("ignores the sweep on its own")
    func ignoresSweep() {
        // The sweep covers the chirp's band, just far more slowly.
        let config = SweepConfig(duration: 2.0, sampleRate: 48_000)
        let sweep = SweepGenerator.makeSweep(config).map { $0 * 0.4 }
        let (samples, _) = recording(silence: 1.0, then: sweep)
        #expect(detector().scan(samples) == nil)
    }

    @Test("stays quiet in a silent room")
    func ignoresSilence() {
        let (samples, _) = recording(silence: 6.0, then: [])
        #expect(detector().scan(samples) == nil)
    }

    @Test("is not fooled by digital silence")
    func digitalSilence() {
        let silent = [Float](repeating: 0, count: Int(6 * sampleRate))
        #expect(detector().scan(silent) == nil)
    }

    // MARK: - Robustness

    @Test("finds a chirp that is quiet but audible")
    func quietChirp() throws {
        let (samples, at) = recording(silence: 2.0, then: chirp.map { $0 * 0.02 },
                                      noise: 0.002)
        let found = try #require(detector().scan(samples))
        #expect(abs(found - at) < Int(0.02 * sampleRate))
    }

    @Test("finds the chirp with noise going on around it")
    func chirpInNoise() throws {
        var rng = SystemRandomNumberGenerator()
        var (samples, at) = recording(silence: 2.0, then: chirp.map { $0 * 0.3 }, noise: 0.02)
        // Somebody talking over the top of it.
        for i in samples.indices where i > Int(1.5 * sampleRate) && i < Int(3.5 * sampleRate) {
            samples[i] += Float.random(in: -0.05...0.05, using: &rng)
        }
        let found = try #require(detector().scan(samples))
        #expect(abs(found - at) < Int(0.02 * sampleRate))
    }

    @Test("catches a chirp that straddles a block boundary")
    func acrossBlockBoundary() throws {
        // Blocks are a second long, so place the chirp deliberately across one.
        for offset in [0.98, 0.99, 1.0, 1.01, 2.0] {
            let (samples, at) = recording(silence: offset, then: chirp.map { $0 * 0.3 })
            let found = try #require(detector().scan(samples),
                                     "missed a chirp starting at \(offset)s")
            #expect(abs(found - at) < Int(0.02 * sampleRate))
        }
    }

    @Test("can be fed the recording repeatedly as it grows")
    func incrementalScanning() throws {
        let (samples, at) = recording(silence: 3.0, then: chirp.map { $0 * 0.3 })
        let detector = self.detector()

        var found: Int?
        var length = 0
        while length < samples.count, found == nil {
            length = Swift.min(samples.count, length + Int(0.3 * sampleRate))
            found = detector.scan(Array(samples[0..<length]))
        }
        #expect(abs(try #require(found) - at) < Int(0.02 * sampleRate))
    }

    @Test("knows how much more audio a complete measurement needs")
    func remaining() {
        let config = SweepConfig(duration: 3, sampleRate: 48_000, preRoll: 2.5,
                                 gap: 0.5, tail: 1.0)
        let stimulus = SweepGenerator.make(config)
        let needed = stimulus.samplesNeededAfterOnset
        // Everything from the chirp onwards, plus the trailing quiet.
        #expect(needed > stimulus.samples.count - stimulus.chirpStart)
        #expect(needed < stimulus.samples.count + Int(2 * 48_000))
    }

    @Test("finds the chirp inside a real stimulus")
    func realStimulus() throws {
        let config = SweepConfig(duration: 1.0, sampleRate: 48_000, preRoll: 0.5,
                                 gap: 0.2, tail: 0.3)
        let stimulus = SweepGenerator.make(config)
        let (samples, at) = recording(silence: 4.0,
                                      then: stimulus.samples.map { $0 * 0.3 })
        let found = try #require(detector().scan(samples))
        #expect(abs(found - (at + stimulus.chirpStart)) < Int(0.02 * sampleRate))
    }
}
