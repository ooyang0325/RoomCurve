import Foundation
import Accelerate

/// A complex spectrum held as separate real and imaginary arrays.
public struct Spectrum: Sendable {
    public var real: [Float]
    public var imag: [Float]

    public init(count: Int) {
        real = [Float](repeating: 0, count: count)
        imag = [Float](repeating: 0, count: count)
    }

    public init(real: [Float], imag: [Float]) {
        precondition(real.count == imag.count)
        self.real = real
        self.imag = imag
    }

    public var count: Int { real.count }

    /// Linear amplitude per bin.
    public var magnitude: [Float] {
        vForce.sqrt(vDSP.add(vDSP.multiply(real, real), vDSP.multiply(imag, imag)))
    }

    /// Phase per bin, wrapped to (−π, π].
    public var phase: [Float] {
        zip(real, imag).map { atan2($1, $0) }
    }

    /// Elementwise complex multiply — convolution in the time domain, and the deconvolution step.
    public func multiplied(by other: Spectrum) -> Spectrum {
        precondition(count == other.count)
        return Spectrum(
            real: vDSP.subtract(vDSP.multiply(real, other.real), vDSP.multiply(imag, other.imag)),
            imag: vDSP.add(vDSP.multiply(real, other.imag), vDSP.multiply(imag, other.real))
        )
    }
}

/// Power-of-two FFT over real-valued signals.
///
/// ponytail: this runs a genuine complex-to-complex transform on a real input rather than the
/// packed real-to-complex form. That costs 2× memory and roughly 2× time, on an operation that
/// runs once per measurement and takes single-digit milliseconds. In exchange the packed
/// format's "DC and Nyquist share element zero, and everything is scaled by two" rule
/// disappears, and with it the class of bug where a complex multiply silently corrupts the two
/// end bins. Move to `vDSP_fft_zrip` only if profiling ever shows this matters.
public final class FFTProcessor {
    public let length: Int
    private let forwardDFT: vDSP.DiscreteFourierTransform<Float>
    private let inverseDFT: vDSP.DiscreteFourierTransform<Float>
    private let zeros: [Float]

    /// - Parameter length: must be a power of two.
    public init(length: Int) {
        precondition(length > 0 && length.nonzeroBitCount == 1, "FFT length must be a power of two")
        self.length = length
        self.zeros = [Float](repeating: 0, count: length)
        do {
            forwardDFT = try vDSP.DiscreteFourierTransform(
                previous: nil, count: length, direction: .forward,
                transformType: .complexComplex, ofType: Float.self)
            inverseDFT = try vDSP.DiscreteFourierTransform(
                previous: nil, count: length, direction: .inverse,
                transformType: .complexComplex, ofType: Float.self)
        } catch {
            preconditionFailure("Could not create DFT setup for length \(length): \(error)")
        }
    }

    /// Smallest power of two greater than or equal to `n`.
    public static func length(atLeast n: Int) -> Int {
        n <= 1 ? 1 : 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount)
    }

    /// Forward transform. Shorter input is zero-padded, longer is truncated.
    public func forward(_ signal: [Float]) -> Spectrum {
        var padded = zeros
        let n = Swift.min(signal.count, length)
        if n > 0 {
            padded.replaceSubrange(0..<n, with: signal[signal.startIndex..<(signal.startIndex + n)])
        }
        let out = forwardDFT.transform(real: padded, imaginary: zeros)
        return Spectrum(real: out.real, imag: out.imaginary)
    }

    /// Inverse transform, returning the real part, scaled so `inverse(forward(x)) == x`.
    public func inverse(_ spectrum: Spectrum) -> [Float] {
        let out = inverseDFT.transform(real: spectrum.real, imaginary: spectrum.imag)
        return vDSP.divide(out.real, Float(length))
    }
}
