import Foundation
import Accelerate

public extension ImpulseResponse {

    /// Build an impulse response that has a given magnitude response and no excess phase.
    ///
    /// This is what lets a pink-noise measurement be saved and equalised through exactly the
    /// same path as a swept-sine one. A real-time analyser only ever recovers magnitude — pink
    /// noise carries no usable phase — but everything downstream (the store, the equaliser, the
    /// exporters) already speaks impulse responses. Rendering the magnitude into one is a lot
    /// less work than teaching all of them about a second kind of measurement.
    ///
    /// The result is **minimum phase**, meaning all its energy sits at and after the peak. A
    /// linear-phase version would be symmetric about the peak, and the analysis window tapers
    /// the 125 ms before the peak — so half the energy would be attenuated on the way back out
    /// and the recovered magnitude would not match what went in.
    static func minimumPhase(magnitudeDB: [Double],
                             grid: LogGrid = .standard,
                             sampleRate: Double = 48_000,
                             length: Int = 65_536) -> ImpulseResponse {
        let fft = FFTProcessor(length: length)
        let binSpacing = sampleRate / Double(length)
        let half = length / 2

        // Log magnitude per bin, held flat outside the measured range so the filter does not
        // invent behaviour where nothing was measured.
        var logMagnitude = [Float](repeating: 0, count: length)
        for k in 0...half {
            let frequency = Double(k) * binSpacing
            let position = grid.index(of: Swift.max(frequency, grid.fMin))
                .clamped(to: 0...Double(grid.count - 1))
            let i = Int(position)
            let t = position - Double(i)
            let dB = i + 1 < magnitudeDB.count
                ? magnitudeDB[i] * (1 - t) + magnitudeDB[i + 1] * t
                : magnitudeDB[Swift.min(i, magnitudeDB.count - 1)]
            let value = Float(Foundation.log(Swift.max(linear(fromDB: dB), 1e-6)))
            logMagnitude[k] = value
            if k > 0 && k < half { logMagnitude[length - k] = value }
        }

        // Real cepstrum, then fold the non-causal half onto the causal one. Doubling the
        // positive-time part and zeroing the negative-time part is what makes the result
        // minimum phase.
        var cepstrum = fft.inverse(Spectrum(real: logMagnitude,
                                            imag: [Float](repeating: 0, count: length)))
        for n in 1..<half { cepstrum[n] *= 2 }
        for n in (half + 1)..<length { cepstrum[n] = 0 }

        // Exponentiate back into a spectrum, and transform to the time domain.
        let spectrum = fft.forward(cepstrum)
        var exponentiated = Spectrum(count: length)
        for k in 0..<length {
            let scale = exp(spectrum.real[k])
            exponentiated.real[k] = scale * cos(spectrum.imag[k])
            exponentiated.imag[k] = scale * sin(spectrum.imag[k])
        }
        let response = fft.inverse(exponentiated)

        // Store on the usual time base: peak at 250 ms within one second.
        let total = Int(ImpulseResponse.storedDuration * sampleRate)
        let peak = Int(ImpulseResponse.peakOffset * sampleRate)
        var samples = [Float](repeating: 0, count: total)
        for i in peak..<total {
            let source = i - peak
            if source < response.count { samples[i] = response[source] }
        }

        return ImpulseResponse(samples: samples, sampleRate: sampleRate, acousticDelay: 0,
                               noiseFloor: [], clockDriftPPM: nil)
    }
}

public extension FrequencyResponse {
    /// Render this response as an impulse response, so a magnitude-only measurement can be
    /// saved and reopened like any other.
    func asImpulseResponse(sampleRate: Double = 48_000) -> ImpulseResponse {
        ImpulseResponse.minimumPhase(magnitudeDB: magnitudeDB, grid: grid,
                                     sampleRate: sampleRate)
    }
}
