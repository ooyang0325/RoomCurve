import Foundation
import Accelerate

/// Parameters for a swept-sine measurement.
public struct SweepConfig: Sendable, Equatable, Codable {
    public var startFrequency: Double
    public var endFrequency: Double
    /// Sweep length. 2–3 s is the sweet spot: long enough for good signal-to-noise, short
    /// enough that sample-clock drift between a wireless endpoint and the phone's ADC has not
    /// accumulated into visible high-frequency phase smear.
    public var duration: Double
    public var sampleRate: Double
    /// Silence before the timing chirp. Serves two purposes: wireless endpoints need a couple
    /// of seconds to lock to the stream before they reproduce anything faithfully, and this
    /// same stretch of recording is the noise-floor sample used for SNR blanking.
    public var preRoll: Double
    /// Silence between the timing chirp and the sweep.
    public var gap: Double
    /// Silence after the sweep, to capture the room's decay.
    public var tail: Double
    /// Half-Hann fade applied to each end of the sweep, to avoid a click.
    public var fade: Double

    public init(startFrequency: Double = 20,
                endFrequency: Double = 20_000,
                duration: Double = 3.0,
                sampleRate: Double = 48_000,
                preRoll: Double = 2.5,
                gap: Double = 0.5,
                tail: Double = 1.0,
                fade: Double = 0.01) {
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.duration = duration
        self.sampleRate = sampleRate
        self.preRoll = preRoll
        self.gap = gap
        self.tail = tail
        self.fade = fade
    }

    /// Sweep rate `R = ln(f2/f1)`.
    public var rate: Double { Foundation.log(endFrequency / startFrequency) }

    /// Time before the impulse response at which the *n*-th harmonic distortion product lands.
    ///
    /// Farina's method places distortion at negative time, `Δtₙ = (T/R)·ln(n)` ahead of the
    /// linear response. The second harmonic is the closest one and therefore sets how far the
    /// pre-peak window may extend before it starts eating distortion instead of signal.
    public func harmonicArrival(_ n: Int) -> Double {
        duration / rate * Foundation.log(Double(n))
    }
}

/// A generated measurement signal, together with everything needed to analyse a recording of it.
public struct SweepStimulus: Sendable {
    public let config: SweepConfig
    /// The full signal to play: pre-roll, chirp, gap, sweep, tail, closing chirp.
    public let samples: [Float]
    /// The timing chirp on its own, used as the correlation reference.
    public let chirp: [Float]
    /// Farina inverse filter for the sweep.
    public let inverseFilter: [Float]

    public let chirpStart: Int
    public let sweepStart: Int
    public let closingChirpStart: Int

    public var sweepLength: Int { inverseFilter.count }
    /// Samples between the start of the chirp and the start of the sweep.
    public var chirpToSweep: Int { sweepStart - chirpStart }
    /// Samples between the two chirps, the baseline for measuring clock drift.
    public var chirpToChirp: Int { closingChirpStart - chirpStart }
}

public enum SweepGenerator {

    /// Build the full stimulus.
    ///
    /// Layout: `preRoll · chirp · gap · sweep · tail · chirp`
    ///
    /// The chirp is what makes measurements comparable to each other. The impulse response peak
    /// alone cannot serve as a time reference, because its position also contains the playback
    /// latency — and over AirPlay that latency varies from one measurement to the next. A chirp
    /// played from a fixed speaker gives every measurement a shared t=0, which is what phase
    /// comparison between speakers (subwoofer time alignment) depends on.
    ///
    /// The closing chirp exists so the elapsed time between the two chirps can be compared with
    /// the interval they were generated at. Any difference is sample-clock drift.
    public static func make(_ config: SweepConfig) -> SweepStimulus {
        let sr = config.sampleRate
        let chirp = makeChirp(sampleRate: sr)
        let sweep = makeSweep(config)
        let inverse = makeInverseFilter(config, sweep: sweep)

        let preRollCount = Int(config.preRoll * sr)
        let gapCount = Int(config.gap * sr)
        let tailCount = Int(config.tail * sr)

        var samples = [Float](repeating: 0, count: preRollCount)
        let chirpStart = samples.count
        samples.append(contentsOf: chirp)
        samples.append(contentsOf: [Float](repeating: 0, count: gapCount))
        let sweepStart = samples.count
        samples.append(contentsOf: sweep)
        samples.append(contentsOf: [Float](repeating: 0, count: tailCount))
        let closingChirpStart = samples.count
        samples.append(contentsOf: chirp)
        samples.append(contentsOf: [Float](repeating: 0, count: Int(0.2 * sr)))

        return SweepStimulus(config: config, samples: samples, chirp: chirp,
                             inverseFilter: inverse, chirpStart: chirpStart,
                             sweepStart: sweepStart, closingChirpStart: closingChirpStart)
    }

    /// Exponential sine sweep: `φ(t) = 2π·f₁·(T/R)·(exp(tR/T) − 1)`.
    static func makeSweep(_ config: SweepConfig) -> [Float] {
        let sr = config.sampleRate
        let n = Int(config.duration * sr)
        let R = config.rate
        let T = config.duration
        let k = 2 * Double.pi * config.startFrequency * T / R

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            out[i] = Float(sin(k * (exp(t * R / T) - 1)))
        }
        applyFades(&out, seconds: config.fade, sampleRate: sr)
        return out
    }

    /// Farina inverse filter: the sweep reversed in time, with an envelope that falls at
    /// 6 dB/octave.
    ///
    /// The sweep's own magnitude spectrum falls at 3 dB/octave, because a logarithmic sweep
    /// lingers proportionally longer at low frequencies. Reversing it leaves that tilt
    /// untouched. The `exp(−tR/T)` envelope contributes +6 dB/octave, so the product rises at
    /// 3 dB/octave — the exact inverse of the sweep, giving a flat deconvolution.
    static func makeInverseFilter(_ config: SweepConfig, sweep: [Float]) -> [Float] {
        let n = sweep.count
        let R = config.rate
        let T = config.duration
        let sr = config.sampleRate

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            out[i] = sweep[n - 1 - i] * Float(exp(-t * R / T))
        }
        return out
    }

    /// Short high-frequency chirp used purely as a timing marker.
    ///
    /// Kept in 2–10 kHz: high enough that correlation gives sharp time resolution, low enough
    /// to stay clear of the region where phone microphones roll off.
    static func makeChirp(sampleRate: Double, duration: Double = 0.2) -> [Float] {
        let n = Int(duration * sampleRate)
        let f1 = 2_000.0, f2 = 10_000.0
        let R = Foundation.log(f2 / f1)
        let k = 2 * Double.pi * f1 * duration / R

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = Float(sin(k * (exp(t * R / duration) - 1)))
        }
        applyFades(&out, seconds: 0.005, sampleRate: sampleRate)
        return out
    }

    /// Half-Hann fade in and out, so the signal never starts or stops on a discontinuity.
    static func applyFades(_ signal: inout [Float], seconds: Double, sampleRate: Double) {
        let f = Swift.min(Int(seconds * sampleRate), signal.count / 2)
        guard f > 0 else { return }
        for i in 0..<f {
            let w = Float(0.5 * (1 - cos(Double.pi * Double(i) / Double(f))))
            signal[i] *= w
            signal[signal.count - 1 - i] *= w
        }
    }
}
