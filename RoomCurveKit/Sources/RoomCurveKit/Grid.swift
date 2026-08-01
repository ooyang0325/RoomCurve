import Foundation
import Accelerate

/// A logarithmically spaced frequency grid, uniform in log2(f).
///
/// Every curve in RoomCurve — measurements, target curves, filter responses, predicted
/// responses, microphone calibrations — is resampled onto one shared instance of this grid.
/// That makes comparison, curve fitting, EQ error and calibration plain elementwise array
/// math instead of a pile of interpolation special cases.
///
/// Uniform spacing in log2(f) also means fractional-octave smoothing is a fixed-width kernel
/// in *index* space, which is why `smoothed(...)` is as short as it is.
public struct LogGrid: Sendable, Equatable {
    public let frequencies: [Double]
    public let pointsPerOctave: Double
    public let fMin: Double
    public let fMax: Double

    /// 1/48 octave from 20 Hz to 20 kHz — 479 points.
    ///
    /// 1/48 octave is finer than the finest smoothing REW offers, so the grid itself never
    /// becomes the resolution limit.
    public static let standard = LogGrid()

    public init(fMin: Double = 20, fMax: Double = 20_000, pointsPerOctave: Double = 48) {
        precondition(fMin > 0 && fMax > fMin && pointsPerOctave > 0)
        self.fMin = fMin
        self.fMax = fMax
        self.pointsPerOctave = pointsPerOctave
        let octaves = log2(fMax / fMin)
        let n = Int((octaves * pointsPerOctave).rounded()) + 1
        let step = octaves / Double(n - 1)
        self.frequencies = (0..<n).map { fMin * exp2(Double($0) * step) }
    }

    public var count: Int { frequencies.count }

    /// Grid index for a frequency, as a continuous value (may be outside 0..<count).
    @inlinable
    public func index(of frequency: Double) -> Double {
        log2(frequency / fMin) * pointsPerOctave
    }

    /// Indices covering `[low, high]`, clamped to the grid.
    public func indices(from low: Double, to high: Double) -> Range<Int> {
        let a = max(0, Int(index(of: low).rounded(.up)))
        let b = min(count, Int(index(of: high).rounded(.down)) + 1)
        return a < b ? a..<b : 0..<0
    }
}

// MARK: - Resampling onto the grid

extension LogGrid {
    /// Interpolate scattered `(frequency, value)` points onto the grid.
    ///
    /// Monotone cubic (Fritsch–Carlson) interpolation in log-frequency. Straight lines between
    /// points leave a visible corner at every control point, and a target curve is meant to
    /// describe a smooth tonal balance rather than a series of hinges. Monotone cubic is the
    /// right kind of smooth here: unlike a natural spline it cannot overshoot between points,
    /// so dragging one point in the editor can never make the curve bulge somewhere else.
    ///
    /// With only two points it reduces to a straight line, and with densely sampled data — a
    /// published target curve, a microphone calibration file — it tracks the points as closely
    /// as linear interpolation would.
    ///
    /// Outside the supplied range the first and last values are held flat, matching how every
    /// other measurement tool reads these files.
    ///
    /// - Parameter points: must be sorted by ascending frequency.
    public func interpolate(points: [(frequency: Double, value: Double)]) -> [Double] {
        guard let first = points.first, let last = points.last else {
            return [Double](repeating: 0, count: count)
        }
        guard points.count > 2 else {
            guard points.count == 2 else {
                return [Double](repeating: first.value, count: count)
            }
            let x0 = log2(first.frequency), x1 = log2(last.frequency)
            return frequencies.map { f in
                if f <= first.frequency { return first.value }
                if f >= last.frequency { return last.value }
                let t = (log2(f) - x0) / (x1 - x0)
                return first.value + t * (last.value - first.value)
            }
        }

        let x = points.map { log2($0.frequency) }
        let y = points.map(\.value)
        let n = points.count

        // Secant slopes between neighbouring points.
        var delta = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = x[i + 1] - x[i]
            delta[i] = h > 0 ? (y[i + 1] - y[i]) / h : 0
        }

        // Tangents: average of neighbouring secants inside, one-sided at the ends.
        var tangent = [Double](repeating: 0, count: n)
        tangent[0] = delta[0]
        tangent[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            tangent[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
        }

        // Fritsch–Carlson limiting — what keeps the curve from overshooting.
        for i in 0..<(n - 1) {
            if delta[i] == 0 {
                tangent[i] = 0
                tangent[i + 1] = 0
                continue
            }
            let a = tangent[i] / delta[i], b = tangent[i + 1] / delta[i]
            let s = a * a + b * b
            if s > 9 {
                let scale = 3 / s.squareRoot()
                tangent[i] = scale * a * delta[i]
                tangent[i + 1] = scale * b * delta[i]
            }
        }

        var out = [Double](repeating: 0, count: count)
        var segment = 0
        for (index, f) in frequencies.enumerated() {
            if f <= first.frequency { out[index] = first.value; continue }
            if f >= last.frequency { out[index] = last.value; continue }

            let xf = log2(f)
            while segment + 1 < n - 1 && x[segment + 1] < xf { segment += 1 }
            let h = x[segment + 1] - x[segment]
            guard h > 0 else { out[index] = y[segment]; continue }

            // Cubic Hermite basis.
            let t = (xf - x[segment]) / h
            let t2 = t * t, t3 = t2 * t
            out[index] = (2 * t3 - 3 * t2 + 1) * y[segment]
                + (t3 - 2 * t2 + t) * h * tangent[segment]
                + (-2 * t3 + 3 * t2) * y[segment + 1]
                + (t3 - t2) * h * tangent[segment + 1]
        }
        return out
    }

    /// Resample a linearly spaced spectrum (FFT bin magnitudes) onto the log grid.
    ///
    /// Where a grid cell spans several FFT bins — which is everywhere above a few hundred Hz
    /// for a long FFT — the bins are *averaged* rather than point-sampled. Point-sampling a
    /// 3000-bin-wide cell at 20 kHz would just be picking one noisy bin and calling it the
    /// answer.
    ///
    /// - Parameters:
    ///   - bins: values indexed by FFT bin, bin *k* being at `k * binSpacing` Hz.
    ///   - binSpacing: `sampleRate / fftLength`.
    public func resample(bins: [Double], binSpacing: Double) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        let halfStep = exp2(0.5 / pointsPerOctave)
        for (i, f) in frequencies.enumerated() {
            let lo = f / halfStep, hi = f * halfStep
            let kLo = Int((lo / binSpacing).rounded()), kHi = Int((hi / binSpacing).rounded())
            if kHi > kLo, kLo >= 0, kHi < bins.count {
                var sum = 0.0
                for k in kLo...kHi { sum += bins[k] }
                out[i] = sum / Double(kHi - kLo + 1)
            } else {
                // Cell narrower than one bin (low frequencies): interpolate between neighbours.
                let x = f / binSpacing
                let k = Int(x.rounded(.down))
                if k >= 0 && k + 1 < bins.count {
                    let t = x - Double(k)
                    out[i] = bins[k] + t * (bins[k + 1] - bins[k])
                } else if k >= 0 && k < bins.count {
                    out[i] = bins[k]
                }
            }
        }
        return out
    }
}

// MARK: - Smoothing

/// Fractional-octave smoothing widths, mirroring the set REW offers.
public enum Smoothing: Sendable, Hashable, CaseIterable {
    case none
    case oct1_1, oct1_3, oct1_6, oct1_12, oct1_24, oct1_48
    /// 1/48 below 100 Hz widening to 1/3 above 10 kHz. REW's recommendation for EQ work.
    case variable
    /// 1/3 below 100 Hz narrowing to 1/6 above 1 kHz — closer to how loudly things register.
    case psychoacoustic

    public var label: String {
        switch self {
        case .none: "None"
        case .oct1_1: "1/1 octave"
        case .oct1_3: "1/3 octave"
        case .oct1_6: "1/6 octave"
        case .oct1_12: "1/12 octave"
        case .oct1_24: "1/24 octave"
        case .oct1_48: "1/48 octave"
        case .variable: "Variable"
        case .psychoacoustic: "Psychoacoustic"
        }
    }

    /// Smoothing width in octaves at a given frequency.
    func widthInOctaves(at frequency: Double) -> Double {
        switch self {
        case .none: 0
        case .oct1_1: 1
        case .oct1_3: 1.0 / 3
        case .oct1_6: 1.0 / 6
        case .oct1_12: 1.0 / 12
        case .oct1_24: 1.0 / 24
        case .oct1_48: 1.0 / 48
        case .variable: Self.ramp(frequency, 100, 1.0 / 48, 10_000, 1.0 / 3)
        case .psychoacoustic: Self.ramp(frequency, 100, 1.0 / 3, 1_000, 1.0 / 6)
        }
    }

    /// Interpolate a width between two anchor frequencies, log-spaced, held flat outside.
    private static func ramp(_ f: Double, _ f0: Double, _ w0: Double,
                             _ f1: Double, _ w1: Double) -> Double {
        if f <= f0 { return w0 }
        if f >= f1 { return w1 }
        let t = log2(f / f0) / log2(f1 / f0)
        return w0 + t * (w1 - w0)
    }
}

extension LogGrid {
    /// Gaussian fractional-octave smoothing.
    ///
    /// **Smooth linear magnitude, not dB and not power.** Smoothing dB values over-weights
    /// dips: a −20 dB notch is a huge excursion in dB but a tiny one in amplitude, so a dB
    /// average gets dragged down by narrow nulls that are barely audible. This matches REW
    /// and the wider measurement literature.
    ///
    /// The width is treated as the Gaussian FWHM, so "1/3 octave" means the kernel is half
    /// amplitude a sixth of an octave either side of centre.
    public func smoothed(linearMagnitude values: [Double], _ smoothing: Smoothing) -> [Double] {
        guard smoothing != .none, values.count == count else { return values }
        var out = [Double](repeating: 0, count: count)
        let fwhmToSigma = 1.0 / (2.0 * (2.0 * Foundation.log(2.0)).squareRoot())

        for i in 0..<count {
            let sigma = smoothing.widthInOctaves(at: frequencies[i]) * pointsPerOctave * fwhmToSigma
            guard sigma > 0.25 else { out[i] = values[i]; continue }
            let radius = Int((sigma * 3).rounded(.up))
            let lo = max(0, i - radius), hi = min(count - 1, i + radius)
            var weighted = 0.0, total = 0.0
            let denom = 2 * sigma * sigma
            for k in lo...hi {
                let d = Double(k - i)
                let w = exp(-d * d / denom)
                weighted += w * values[k]
                total += w
            }
            out[i] = weighted / total
        }
        return out
    }
}

// MARK: - dB helpers

@inlinable public func dB(fromLinear x: Double) -> Double { 20 * Foundation.log10(max(x, 1e-12)) }
@inlinable public func linear(fromDB x: Double) -> Double { pow(10, x / 20) }

public extension Array where Element == Double {
    var asDB: [Double] { map { dB(fromLinear: $0) } }
    var asLinear: [Double] { map { linear(fromDB: $0) } }
}
