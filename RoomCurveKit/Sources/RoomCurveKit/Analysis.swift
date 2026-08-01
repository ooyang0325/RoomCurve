import Foundation
import Accelerate

/// How the impulse response is gated before its spectrum is taken.
public struct IRWindow: Sendable, Equatable {
    /// Seconds of response kept before the peak.
    public var left: Double
    /// Seconds kept after the peak.
    public var right: Double

    /// REW's defaults for a full-range room measurement.
    ///
    /// The left window has a hard ceiling that comes out of the sweep method itself: harmonic
    /// distortion products land at negative time, the second harmonic at `(T/R)·ln 2` before
    /// the response. For a 3 s sweep over 20 Hz–20 kHz that is 301 ms, so 125 ms leaves
    /// comfortable clearance. Widening it past that measures distortion, not response.
    public static let standard = IRWindow(left: 0.125, right: 0.5)

    public init(left: Double, right: Double) {
        self.left = left
        self.right = right
    }

    public var duration: Double { left + right }
}

/// A measured or derived response, sampled on the shared log-frequency grid.
public struct FrequencyResponse: Sendable {
    public let grid: LogGrid
    public let magnitudeDB: [Double]
    public let phaseDegrees: [Double]
    public let groupDelayMS: [Double]
    /// Per-frequency signal-to-noise, used to blank regions the measurement cannot support.
    public let snrDB: [Double]

    public init(grid: LogGrid, magnitudeDB: [Double], phaseDegrees: [Double],
                groupDelayMS: [Double], snrDB: [Double]) {
        self.grid = grid
        self.magnitudeDB = magnitudeDB
        self.phaseDegrees = phaseDegrees
        self.groupDelayMS = groupDelayMS
        self.snrDB = snrDB
    }

    /// Frequencies whose signal-to-noise is too low to be worth showing or equalising.
    ///
    /// Below roughly 10 dB SNR the magnitude error from noise alone exceeds a couple of dB, so
    /// what is drawn there is mostly the room's noise floor rather than the loudspeaker. Also
    /// the honest way to show where a speaker simply stops producing output.
    public func blanked(belowSNR threshold: Double) -> [Bool] {
        snrDB.map { $0 < threshold }
    }

    /// Apply a microphone calibration, in dB, already on the grid.
    ///
    /// The calibration describes *the microphone's* deviation from flat, and is therefore
    /// subtracted. This is the convention every calibration file you can download follows —
    /// a UMIK-1 file with `-8.0` at 20 Hz means the capsule reads 8 dB low there, so the
    /// measurement must be raised by 8 dB, not lowered.
    public func applying(calibrationDB: [Double]) -> FrequencyResponse {
        guard calibrationDB.count == magnitudeDB.count else { return self }
        return FrequencyResponse(
            grid: grid,
            magnitudeDB: zip(magnitudeDB, calibrationDB).map(-),
            phaseDegrees: phaseDegrees, groupDelayMS: groupDelayMS, snrDB: snrDB)
    }

    /// Smooth the magnitude. Phase and group delay are smoothed alongside it, which is what
    /// keeps group delay readable — it is a derivative, so it amplifies whatever noise the
    /// phase carries.
    public func smoothed(_ smoothing: Smoothing) -> FrequencyResponse {
        guard smoothing != .none else { return self }
        let linear = grid.smoothed(linearMagnitude: magnitudeDB.asLinear, smoothing)
        return FrequencyResponse(
            grid: grid,
            magnitudeDB: linear.asDB,
            phaseDegrees: grid.smoothed(linearMagnitude: phaseDegrees, smoothing),
            groupDelayMS: grid.smoothed(linearMagnitude: groupDelayMS, smoothing),
            snrDB: snrDB)
    }

    /// Root-mean-square average of several measurements.
    ///
    /// Positions in a listening area are acoustically incoherent with one another — there is no
    /// consistent phase relationship between them, and nobody sits in two seats at once. So
    /// magnitudes are power-averaged and phase is dropped. Averaging the complex responses
    /// instead would manufacture cancellation artefacts that no listener ever hears.
    /// This is also what a moving-microphone measurement converges to.
    public static func average(_ responses: [FrequencyResponse]) -> FrequencyResponse? {
        guard let first = responses.first else { return nil }
        guard responses.count > 1 else { return first }
        let grid = first.grid
        let n = grid.count
        let count = Double(responses.count)

        var power = [Double](repeating: 0, count: n)
        var snr = [Double](repeating: 0, count: n)
        for r in responses {
            for i in 0..<n {
                let linear = linear(fromDB: r.magnitudeDB[i])
                power[i] += linear * linear
                snr[i] += r.snrDB[i]
            }
        }

        return FrequencyResponse(
            grid: grid,
            magnitudeDB: (0..<n).map { dB(fromLinear: (power[$0] / count).squareRoot()) },
            // Phase and group delay belong to a single position, so the first is carried
            // through rather than averaged into something meaningless.
            phaseDegrees: first.phaseDegrees,
            groupDelayMS: first.groupDelayMS,
            snrDB: (0..<n).map { snr[$0] / count })
    }
}

public enum Analyser {

    /// Turn an impulse response into magnitude, phase, group delay and signal-to-noise.
    public static func response(of ir: ImpulseResponse,
                                window: IRWindow = .standard,
                                grid: LogGrid = .standard) -> FrequencyResponse {
        let sr = ir.sampleRate
        let peak = Deconvolver.peakIndex(of: ir.samples) ?? ir.peakIndex

        let gated = gate(ir.samples, peak: peak, window: window, sampleRate: sr)
        let fftLength = FFTProcessor.length(atLeast: Swift.max(gated.count, Int(sr)))
        let fft = FFTProcessor(length: fftLength)
        let spectrum = fft.forward(gated)
        let binSpacing = sr / Double(fftLength)
        let usable = fftLength / 2

        let magnitude = Array(spectrum.magnitude[0..<usable]).map(Double.init)
        let gridMagnitude = grid.resample(bins: magnitude, binSpacing: binSpacing)

        let (gridPhase, gridGroupDelay) = phaseAndGroupDelay(
            spectrum: spectrum, usable: usable, binSpacing: binSpacing, grid: grid)

        let snr = signalToNoise(ir: ir, peak: peak, window: window,
                                signalMagnitude: gridMagnitude,
                                fft: fft, binSpacing: binSpacing, grid: grid)

        return FrequencyResponse(grid: grid,
                                 magnitudeDB: gridMagnitude.asDB,
                                 phaseDegrees: gridPhase,
                                 groupDelayMS: gridGroupDelay,
                                 snrDB: snr)
    }

    // MARK: - Steps

    /// Gate the response around its peak.
    ///
    /// Half-Hann rise on the left, flat then tapered on the right. The right side stays flat as
    /// long as possible so the room's decay is preserved rather than squashed, which matters
    /// below the Schroeder frequency where that decay *is* the thing being corrected.
    static func gate(_ samples: [Float], peak: Int, window: IRWindow,
                     sampleRate: Double) -> [Float] {
        let leftCount = Int(window.left * sampleRate)
        let rightCount = Int(window.right * sampleRate)
        let start = Swift.max(0, peak - leftCount)
        let end = Swift.min(samples.count, peak + rightCount)
        guard start < end else { return [] }

        var out = Array(samples[start..<end])
        let peakInWindow = peak - start

        for i in 0..<peakInWindow {
            let w = 0.5 * (1 - cos(Double.pi * Double(i) / Double(peakInWindow)))
            out[i] *= Float(w)
        }
        // Taper the last quarter of the right side to avoid a truncation edge.
        let tail = (out.count - peakInWindow) / 4
        if tail > 1 {
            for i in 0..<tail {
                let w = 0.5 * (1 + cos(Double.pi * Double(i) / Double(tail)))
                out[out.count - tail + i] *= Float(w)
            }
        }
        return out
    }

    /// Wrapped phase for display, and group delay from the slope of the unwrapped phase.
    static func phaseAndGroupDelay(spectrum: Spectrum, usable: Int, binSpacing: Double,
                                   grid: LogGrid) -> (phase: [Double], groupDelay: [Double]) {
        var unwrapped = [Double](repeating: 0, count: usable)
        var previous = 0.0
        var offset = 0.0
        for k in 0..<usable {
            let raw = atan2(Double(spectrum.imag[k]), Double(spectrum.real[k]))
            if k > 0 {
                let delta = raw - previous
                if delta > .pi { offset -= 2 * .pi }
                else if delta < -.pi { offset += 2 * .pi }
            }
            previous = raw
            unwrapped[k] = raw + offset
        }

        // Group delay is −dφ/dω, in milliseconds.
        var groupDelay = [Double](repeating: 0, count: usable)
        let dOmega = 2 * Double.pi * binSpacing
        for k in 0..<usable {
            let a = unwrapped[Swift.max(0, k - 1)]
            let b = unwrapped[Swift.min(usable - 1, k + 1)]
            let span = Double(Swift.min(usable - 1, k + 1) - Swift.max(0, k - 1))
            groupDelay[k] = span > 0 ? -(b - a) / (span * dOmega) * 1000 : 0
        }

        let gridUnwrapped = grid.resample(bins: unwrapped, binSpacing: binSpacing)
        let gridGroupDelay = grid.resample(bins: groupDelay, binSpacing: binSpacing)

        // Re-wrap to ±180° for display. The vertical jumps this creates are an artefact of the
        // plot, not a real 360° step in the response.
        let wrapped = gridUnwrapped.map { phase -> Double in
            var d = phase * 180 / .pi
            d = d.truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }
        return (wrapped, gridGroupDelay)
    }

    /// Per-frequency signal-to-noise.
    ///
    /// The reference is ambient noise recorded with no test signal playing, put through the
    /// same deconvolution as the measurement, and gated with the same window. Identical
    /// processing and identical length means the two spectra can be divided directly.
    ///
    /// The tempting shortcut — taking the noise from the tail of the impulse response — measures
    /// the room still decaying rather than the noise floor, and rooms decay for a long time
    /// down low. That reads as poor signal-to-noise exactly where the measurement matters most,
    /// and blanks most of the trace.
    ///
    /// With no usable reference, nothing is blanked. Showing the whole measurement and trusting
    /// the user beats hiding most of it on the strength of a bad noise estimate.
    static func signalToNoise(ir: ImpulseResponse, peak: Int, window: IRWindow,
                              signalMagnitude: [Double], fft: FFTProcessor,
                              binSpacing: Double, grid: LogGrid) -> [Double] {
        guard ir.noiseFloor.count == ir.samples.count else {
            return [Double](repeating: .infinity, count: grid.count)
        }
        let gatedNoise = gate(ir.noiseFloor, peak: peak, window: window,
                              sampleRate: ir.sampleRate)
        guard !gatedNoise.isEmpty else {
            return [Double](repeating: .infinity, count: grid.count)
        }
        let usable = fft.length / 2
        let magnitude = Array(fft.forward(gatedNoise).magnitude[0..<usable]).map(Double.init)
        let gridNoise = grid.resample(bins: magnitude, binSpacing: binSpacing)

        return zip(signalMagnitude, gridNoise).map { signal, noise in
            guard noise > 1e-12 else { return Double.infinity }
            return 20 * Foundation.log10(signal / noise)
        }
    }
}
