import Testing
import Foundation
@testable import RoomCurveKit

/// Convolve a signal with a system impulse response, the way a room would.
private func convolve(_ signal: [Float], with ir: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: signal.count + ir.count - 1)
    for (i, h) in ir.enumerated() where h != 0 {
        for n in 0..<signal.count { out[n + i] += signal[n] * h }
    }
    return out
}

/// A recording of the stimulus played through `systemIR`, delayed by `latency` samples.
private func simulateRecording(_ stimulus: SweepStimulus,
                               systemIR: [Float],
                               latency: Int,
                               noise: Float = 0) -> [Float] {
    let played = convolve(stimulus.samples, with: systemIR)
    var recording = [Float](repeating: 0, count: latency)
    recording.append(contentsOf: played)
    recording.append(contentsOf: [Float](repeating: 0, count: 4800))
    if noise > 0 {
        var rng = SystemRandomNumberGenerator()
        for i in recording.indices {
            recording[i] += Float.random(in: -noise...noise, using: &rng)
        }
    }
    return recording
}

/// A short config, so tests stay fast.
private let testConfig = SweepConfig(duration: 1.0, sampleRate: 48_000,
                                     preRoll: 0.3, gap: 0.2, tail: 0.3)

@Suite("Sweep generation")
struct SweepGenerationTests {

    @Test("sweep starts and ends at the requested frequencies")
    func sweepFrequencyRange() {
        let config = SweepConfig(startFrequency: 20, endFrequency: 20_000,
                                 duration: 2, sampleRate: 48_000)
        let sweep = SweepGenerator.makeSweep(config)
        #expect(sweep.count == 96_000)

        // Estimate instantaneous frequency by counting zero crossings in a short slice.
        func frequency(around index: Int, span: Int = 2400) -> Double {
            var crossings = 0
            for i in (index + 1)..<(index + span) {
                if (sweep[i - 1] < 0) != (sweep[i] < 0) { crossings += 1 }
            }
            return Double(crossings) / 2 * (48_000 / Double(span))
        }
        // Skip the fade regions at each end.
        #expect(abs(frequency(around: 2_400) - 20) < 15)
        #expect(abs(frequency(around: 91_000) / 20_000 - 1) < 0.25)
    }

    @Test("fades remove the discontinuity at each end")
    func fades() {
        let sweep = SweepGenerator.makeSweep(testConfig)
        #expect(abs(sweep.first!) < 0.01)
        #expect(abs(sweep.last!) < 0.01)
    }

    @Test("sweep convolved with its inverse filter gives a single clean peak")
    func inverseFilterFlattens() {
        let config = SweepConfig(duration: 1.0, sampleRate: 48_000)
        let sweep = SweepGenerator.makeSweep(config)
        let inverse = SweepGenerator.makeInverseFilter(config, sweep: sweep)
        let result = Deconvolver.linearConvolve(sweep, inverse)

        let peak = Deconvolver.peakIndex(of: result)!
        // The peak lands one filter length in, because the inverse filter is time-reversed.
        #expect(abs(peak - (sweep.count - 1)) <= 2)
        // And it must dominate: everything well away from it is far smaller.
        let peakValue = abs(result[peak])
        let far = result[0..<(peak - 4800)].map { abs($0) }.max()!
        #expect(far < peakValue * 0.05)
    }

    @Test("stimulus lays out pre-roll, chirp, gap, sweep, tail and closing chirp in order")
    func layout() {
        let s = SweepGenerator.make(testConfig)
        #expect(s.chirpStart == Int(0.3 * 48_000))
        #expect(s.sweepStart == s.chirpStart + s.chirp.count + Int(0.2 * 48_000))
        #expect(s.closingChirpStart > s.sweepStart + s.sweepLength)
        #expect(s.chirpToSweep == s.sweepStart - s.chirpStart)
    }
}

@Suite("Deconvolution")
struct DeconvolutionTests {

    @Test("recovers a known impulse response through unknown playback latency")
    func roundTrip() throws {
        let stimulus = SweepGenerator.make(testConfig)
        // A system with a direct arrival and one reflection.
        var systemIR = [Float](repeating: 0, count: 400)
        systemIR[0] = 1.0
        systemIR[240] = -0.4

        // Latency the analysis is not told about, as with AirPlay.
        let recording = simulateRecording(stimulus, systemIR: systemIR, latency: 7_000)
        let result = try Deconvolver.analyse(recording: recording, stimulus: stimulus)

        let peak = result.peakIndex
        let normalise = result.samples[peak]
        #expect(normalise > 0)
        // The reflection must reappear at the right offset with the right sign and level.
        let reflection = result.samples[peak + 240] / normalise
        #expect(abs(reflection - (-0.4)) < 0.05)
    }

    @Test("reports the sweep's arrival relative to the timing chirp")
    func acousticDelayIsRelativeToChirp() throws {
        let stimulus = SweepGenerator.make(testConfig)
        let impulse: [Float] = [1.0]

        // Chirp and sweep travelling the same path: no relative delay.
        let common = simulateRecording(stimulus, systemIR: impulse, latency: 5_000)
        let a = try Deconvolver.analyse(recording: common, stimulus: stimulus)
        #expect(abs(a.acousticDelay) < 0.0005)

        // Now delay only the sweep, as a subwoofer further away would be.
        let extra = 96 // 2 ms at 48 kHz
        var split = common
        let sweepAt = 5_000 + stimulus.sweepStart
        let sweepEnd = sweepAt + stimulus.sweepLength
        var shifted = [Float](repeating: 0, count: split.count)
        for i in 0..<split.count {
            let src = i - extra
            if src >= sweepAt && src < sweepEnd { shifted[i] = split[src] }
        }
        for i in sweepAt..<Swift.min(sweepEnd + extra, split.count) { split[i] = shifted[i] }

        let b = try Deconvolver.analyse(recording: split, stimulus: stimulus)
        #expect(abs(b.acousticDelay - Double(extra) / 48_000) < 0.0005)
    }

    @Test("removeDelay pins the peak to the storage offset")
    func removeDelay() throws {
        let stimulus = SweepGenerator.make(testConfig)
        let recording = simulateRecording(stimulus, systemIR: [1.0], latency: 9_000)
        let ir = try Deconvolver.analyse(recording: recording, stimulus: stimulus,
                                         removeDelay: true)
        let peak = Deconvolver.peakIndex(of: ir.samples)!
        #expect(abs(peak - ir.peakIndex) <= 1)
    }

    @Test("rejects a recording with no test signal in it")
    func noSignal() {
        let stimulus = SweepGenerator.make(testConfig)
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<300_000).map { _ in Float.random(in: -0.01...0.01, using: &rng) }
        #expect(throws: MeasurementError.testSignalNotDetected) {
            try Deconvolver.analyse(recording: noise, stimulus: stimulus)
        }
    }

    @Test("rejects a recording that stops early")
    func truncated() {
        let stimulus = SweepGenerator.make(testConfig)
        #expect(throws: MeasurementError.recordingTooShort) {
            try Deconvolver.analyse(recording: [Float](repeating: 0, count: 1000),
                                    stimulus: stimulus)
        }
    }

    @Test("survives a noisy recording")
    func withNoise() throws {
        let stimulus = SweepGenerator.make(testConfig)
        var systemIR = [Float](repeating: 0, count: 400)
        systemIR[0] = 1.0
        systemIR[240] = -0.4
        let recording = simulateRecording(stimulus, systemIR: systemIR,
                                          latency: 6_000, noise: 0.02)
        let result = try Deconvolver.analyse(recording: recording, stimulus: stimulus)
        let peak = result.peakIndex
        let reflection = result.samples[peak + 240] / result.samples[peak]
        #expect(abs(reflection - (-0.4)) < 0.08)
    }

    @Test("measures sample clock drift from the two chirps")
    func clockDrift() throws {
        let stimulus = SweepGenerator.make(testConfig)
        let recording = simulateRecording(stimulus, systemIR: [1.0], latency: 5_000)
        let result = try Deconvolver.analyse(recording: recording, stimulus: stimulus)
        // Playback and capture share a clock here, so drift must read as ~0.
        let drift = try #require(result.clockDriftPPM)
        #expect(abs(drift) < 500)
    }
}
