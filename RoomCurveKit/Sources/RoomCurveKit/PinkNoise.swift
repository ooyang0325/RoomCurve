import Foundation
import Accelerate

/// Pink noise, and the reference spectrum needed to interpret a recording of it.
public struct PinkNoiseStimulus: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Long-term average power of this exact signal, on the shared grid.
    ///
    /// Measured from the generated buffer rather than assumed to be a textbook 1/f slope. The
    /// generator is a filter approximation, accurate to a fraction of a dB but not exact, and
    /// any error in the reference would otherwise be read as a defect in the loudspeaker.
    public let referencePower: [Double]
}

public enum PinkNoiseGenerator {

    /// Paul Kellet's filtered-white pink noise, accurate to about ±0.5 dB down to a few hertz.
    public static func make(duration: Double = 60,
                            sampleRate: Double = 48_000,
                            grid: LogGrid = .standard,
                            seed: UInt64 = 0x52_6F_6F_6D) -> PinkNoiseStimulus {
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var rng = SplitMix64(seed: seed)

        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        for i in 0..<count {
            let white = rng.nextUniform()
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            samples[i] = Float(pink)
        }

        // Normalise to a comfortable level with headroom for the crest factor.
        let peak = samples.map(abs).max() ?? 1
        if peak > 0 { samples = vDSP.multiply(0.25 / peak, samples) }

        SweepGenerator.applyFades(&samples, seconds: 0.05, sampleRate: sampleRate)

        let reference = averagePowerSpectrum(samples, sampleRate: sampleRate, grid: grid)
        return PinkNoiseStimulus(samples: samples, sampleRate: sampleRate,
                                 referencePower: reference)
    }

    /// Welch average of the power spectrum, on the grid.
    static func averagePowerSpectrum(_ signal: [Float], sampleRate: Double,
                                     grid: LogGrid, blockSize: Int = 16_384) -> [Double] {
        let fft = FFTProcessor(length: blockSize)
        let window = hann(blockSize)
        let hop = blockSize / 2
        let usable = blockSize / 2
        let binSpacing = sampleRate / Double(blockSize)

        var accumulated = [Double](repeating: 0, count: usable)
        var blocks = 0
        var start = 0
        while start + blockSize <= signal.count {
            let block = vDSP.multiply(Array(signal[start..<(start + blockSize)]), window)
            let magnitude = fft.forward(block).magnitude
            for k in 0..<usable {
                let value = Double(magnitude[k])
                accumulated[k] += value * value
            }
            blocks += 1
            start += hop
        }
        guard blocks > 0 else { return [Double](repeating: 1, count: grid.count) }
        let mean = accumulated.map { $0 / Double(blocks) }
        return grid.resample(bins: mean, binSpacing: binSpacing).map { Swift.max($0, 1e-20) }
    }

    static func hann(_ n: Int) -> [Float] {
        (0..<n).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n)))) }
    }
}

/// Deterministic RNG, so a generated noise file is reproducible.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in −1...1.
    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 52) * 2 - 1
    }
}

/// Live pink-noise analysis.
///
/// Two modes, matching the two things people actually do with an RTA:
/// - `live` shows a short running average, so a change to a control is visible as it is made.
/// - `average` accumulates indefinitely, which is what a moving-microphone measurement needs:
///   walk the microphone around the listening area and the standing-wave pattern averages out.
///
/// Both average *power*, which is the correct operation for combining acoustically incoherent
/// samples of a sound field.
public final class RealTimeAnalyser {
    public enum Mode: Sendable, Hashable, CaseIterable {
        case live, average

        public var label: String {
            switch self {
            case .live: "Live"
            case .average: "Average"
            }
        }
    }

    public var mode: Mode {
        didSet { if mode != oldValue { reset() } }
    }

    private let stimulus: PinkNoiseStimulus
    private let grid: LogGrid
    private let blockSize: Int
    private let fft: FFTProcessor
    private let window: [Float]
    private let binSpacing: Double

    private var pending: [Float] = []
    private var accumulated: [Double]
    private var blocks = 0

    /// Weight given to each new block in live mode, chosen so the average settles over about
    /// five seconds — long enough to be stable, short enough to feel responsive.
    private let liveWeight: Double

    public init(stimulus: PinkNoiseStimulus, grid: LogGrid = .standard,
                blockSize: Int = 16_384, mode: Mode = .live) {
        self.stimulus = stimulus
        self.grid = grid
        self.blockSize = blockSize
        self.mode = mode
        self.fft = FFTProcessor(length: blockSize)
        self.window = PinkNoiseGenerator.hann(blockSize)
        self.binSpacing = stimulus.sampleRate / Double(blockSize)
        self.accumulated = [Double](repeating: 0, count: blockSize / 2)

        let blocksPerSecond = stimulus.sampleRate / Double(blockSize / 2)
        self.liveWeight = 1 - exp(-1 / (5 * blocksPerSecond))
    }

    public func reset() {
        pending.removeAll(keepingCapacity: true)
        accumulated = [Double](repeating: 0, count: blockSize / 2)
        blocks = 0
    }

    /// Feed captured audio. Safe to call with any buffer size.
    public func process(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        let hop = blockSize / 2
        while pending.count >= blockSize {
            processBlock(Array(pending[0..<blockSize]))
            pending.removeFirst(hop)
        }
    }

    private func processBlock(_ block: [Float]) {
        let magnitude = fft.forward(vDSP.multiply(block, window)).magnitude
        blocks += 1
        for k in 0..<accumulated.count {
            let value = Double(magnitude[k])
            let power = value * value
            switch mode {
            case .live:
                accumulated[k] += (power - accumulated[k]) * (blocks == 1 ? 1 : liveWeight)
            case .average:
                accumulated[k] += (power - accumulated[k]) / Double(blocks)
            }
        }
    }

    public var hasData: Bool { blocks > 0 }

    /// The system's magnitude response: what came back, divided by what was sent.
    public func response() -> FrequencyResponse? {
        guard blocks > 0 else { return nil }
        let measured = grid.resample(bins: accumulated, binSpacing: binSpacing)
        let magnitudeDB = (0..<grid.count).map { i -> Double in
            let ratio = measured[i] / stimulus.referencePower[i]
            return 10 * Foundation.log10(Swift.max(ratio, 1e-20))
        }
        let zeros = [Double](repeating: 0, count: grid.count)
        return FrequencyResponse(grid: grid, magnitudeDB: magnitudeDB,
                                 // Pink noise carries no usable phase information, so the
                                 // phase and group delay plots stay empty in this mode.
                                 phaseDegrees: zeros, groupDelayMS: zeros,
                                 snrDB: [Double](repeating: .infinity, count: grid.count))
    }
}
