import Foundation
import Accelerate

public enum MeasurementError: Error, LocalizedError, Equatable {
    case testSignalNotDetected
    case lowSignalToNoise(Double)
    case recordingTooShort

    public var errorDescription: String? {
        switch self {
        case .testSignalNotDetected:
            "Could not detect the test signal. Check the volume, the connection, and that "
            + "nothing is covering the microphone."
        case .lowSignalToNoise(let snr):
            "Measurement too noisy (\(Int(snr)) dB signal to noise). Raise the volume or "
            + "reduce background noise."
        case .recordingTooShort:
            "The recording ended before the test signal finished."
        }
    }
}

/// A measured impulse response, stored with the peak at 250 ms in a one-second buffer —
/// the same convention HouseCurve uses for its exported WAV files.
public struct ImpulseResponse: Sendable {
    public static let peakOffset = 0.25
    public static let storedDuration = 1.0

    public let samples: [Float]
    public let sampleRate: Double
    /// Arrival time of this measurement relative to the timing chirp, in seconds. Comparable
    /// across measurements as long as the chirp came from the same speaker each time.
    public let acousticDelay: Double
    /// Ambient noise put through the same deconvolution as the measurement, so the two can be
    /// compared directly. Same length as `samples`.
    public let noiseFloor: [Float]
    /// Sample-clock drift between playback and capture, in parts per million, when both
    /// timing chirps were found.
    public let clockDriftPPM: Double?

    public init(samples: [Float], sampleRate: Double, acousticDelay: Double,
                noiseFloor: [Float], clockDriftPPM: Double?) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.acousticDelay = acousticDelay
        self.noiseFloor = noiseFloor
        self.clockDriftPPM = clockDriftPPM
    }

    public var peakIndex: Int { Int(Self.peakOffset * sampleRate) }
}

public enum Deconvolver {

    /// Recover the impulse response from a recording of the stimulus.
    ///
    /// - Parameter removeDelay: shift the response so its peak sits exactly at the stored
    ///   peak offset. Enable when averaging measurements — a listener cannot sit in two seats
    ///   at once, so differing arrival times would otherwise smear the average. Disable when
    ///   time-aligning speakers, where that arrival difference is the whole measurement.
    public static func analyse(recording: [Float],
                               stimulus: SweepStimulus,
                               removeDelay: Bool = true,
                               minimumSNR: Double = 6) throws -> ImpulseResponse {
        let sr = stimulus.config.sampleRate
        guard recording.count > stimulus.sweepStart + stimulus.sweepLength else {
            throw MeasurementError.recordingTooShort
        }

        guard let chirpArrival = findChirp(in: recording, reference: stimulus.chirp) else {
            throw MeasurementError.testSignalNotDetected
        }

        // Deconvolve a window around where the sweep is expected, rather than the whole
        // recording: it halves the FFT size and keeps unrelated noise out of the result.
        let margin = Int(0.25 * sr)
        let expectedSweep = chirpArrival + stimulus.chirpToSweep
        let windowStart = Swift.max(0, expectedSweep - margin)
        let windowEnd = Swift.min(recording.count,
                                  expectedSweep + stimulus.sweepLength
                                      + Int(stimulus.config.tail * sr) + margin)
        guard windowEnd - windowStart > stimulus.sweepLength else {
            throw MeasurementError.recordingTooShort
        }
        let window = Array(recording[windowStart..<windowEnd])

        // Ambient noise: a stretch of the recording containing no test signal, put through the
        // same deconvolution so it is directly comparable with the measurement.
        let noiseFloor = deconvolvedNoise(recording: recording, stimulus: stimulus,
                                          length: windowEnd - windowStart,
                                          avoiding: windowStart..<windowEnd)

        let deconvolved = linearConvolve(window, stimulus.inverseFilter)

        // The inverse filter is time-reversed, so the response peak lands one filter-length
        // along from where the sweep actually started.
        guard let peak = peakIndex(of: deconvolved) else {
            throw MeasurementError.testSignalNotDetected
        }
        let sweepArrival = windowStart + peak - (stimulus.sweepLength - 1)
        let acousticDelay = Double(sweepArrival - expectedSweep) / sr

        let snr = signalToNoise(deconvolved, peak: peak)
        guard snr >= minimumSNR else { throw MeasurementError.lowSignalToNoise(snr) }

        let ir = extract(deconvolved, peak: peak, sampleRate: sr,
                         extraDelay: removeDelay ? 0 : acousticDelay)

        let drift = estimateClockDrift(recording: recording, stimulus: stimulus,
                                       firstChirpAt: chirpArrival)

        // Cut the noise reference to the same length and offset as the response, so the two
        // can be windowed identically and compared bin for bin with no length correction.
        let noiseReference = noiseFloor.isEmpty ? []
            : extract(noiseFloor, peak: Swift.min(peak, noiseFloor.count - 1),
                      sampleRate: sr, extraDelay: 0)

        return ImpulseResponse(samples: ir, sampleRate: sr, acousticDelay: acousticDelay,
                               noiseFloor: noiseReference, clockDriftPPM: drift)
    }

    // MARK: - Steps

    /// Locate the timing chirp by matched filtering.
    ///
    /// Takes the *first* correlation peak that stands well clear of the background, not the
    /// largest one. Two things make the largest peak the wrong choice: the stimulus deliberately
    /// contains a second, identical chirp at the end, so whichever of the two happens to
    /// correlate a hair higher would win at random; and a strong early reflection can outrank
    /// the direct arrival. The first qualifying peak is the direct sound, which is what t=0 means.
    ///
    /// Returns nil when nothing stands clear of the background, which is what "could not detect
    /// test signal" means in practice.
    static func findChirp(in recording: [Float], reference: [Float]) -> Int? {
        let reversed = [Float](reference.reversed())
        let correlation = linearConvolve(recording, reversed)
        guard let strongest = peakIndex(of: correlation) else { return nil }

        let peakValue = abs(correlation[strongest])
        let rms = sqrt(vDSP.meanSquare(correlation))
        guard rms > 0, peakValue / rms > 8 else { return nil }

        // First crossing of half the strongest peak, then the local maximum around it.
        let threshold = peakValue * 0.5
        guard let firstCrossing = correlation.firstIndex(where: { abs($0) >= threshold }) else {
            return nil
        }
        let searchEnd = Swift.min(correlation.count, firstCrossing + reference.count)
        var peak = firstCrossing
        for i in firstCrossing..<searchEnd where abs(correlation[i]) > abs(correlation[peak]) {
            peak = i
        }

        let arrival = peak - (reference.count - 1)
        return arrival >= 0 ? arrival : nil
    }

    /// Zero-padded FFT convolution.
    ///
    /// The padding to `a.count + b.count − 1` is what keeps this a *linear* convolution;
    /// without it the FFT gives a circular one and the tail of the response wraps around into
    /// the head.
    static func linearConvolve(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = FFTProcessor.length(atLeast: a.count + b.count - 1)
        let fft = FFTProcessor(length: n)
        return fft.inverse(fft.forward(a).multiplied(by: fft.forward(b)))
    }

    static func peakIndex(of signal: [Float]) -> Int? {
        guard !signal.isEmpty else { return nil }
        var maxValue: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxmgvi(signal, 1, &maxValue, &index, vDSP_Length(signal.count))
        return maxValue > 0 ? Int(index) : nil
    }

    /// Signal-to-noise estimated from the deconvolved response: the peak against the
    /// background level well away from it, where only noise should remain.
    static func signalToNoise(_ deconvolved: [Float], peak: Int) -> Double {
        let guardBand = deconvolved.count / 20
        var noise: [Float] = []
        if peak > 2 * guardBand {
            noise.append(contentsOf: deconvolved[0..<(peak - 2 * guardBand)])
        }
        if peak + 2 * guardBand < deconvolved.count {
            noise.append(contentsOf: deconvolved[(peak + 2 * guardBand)...])
        }
        guard !noise.isEmpty else { return 0 }
        let noiseRMS = sqrt(vDSP.meanSquare(noise))
        guard noiseRMS > 0 else { return .infinity }
        return 20 * Foundation.log10(Double(abs(deconvolved[peak]) / noiseRMS))
    }

    /// Cut the response out of the deconvolution and place it at the storage convention:
    /// peak at 250 ms within a one-second buffer.
    static func extract(_ deconvolved: [Float], peak: Int, sampleRate: Double,
                        extraDelay: Double) -> [Float] {
        let total = Int(ImpulseResponse.storedDuration * sampleRate)
        let target = Int(ImpulseResponse.peakOffset * sampleRate)
            + Int((extraDelay * sampleRate).rounded())

        var out = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let source = peak - target + i
            if source >= 0 && source < deconvolved.count { out[i] = deconvolved[source] }
        }
        return out
    }

    /// Deconvolve a stretch of recording that contains no test signal.
    ///
    /// The point is to measure the noise floor *after* the same processing the measurement went
    /// through, so the comparison is like for like. Taking the noise from the tail of the
    /// impulse response instead — which is the obvious shortcut — measures the room still
    /// ringing rather than the noise, and in the bass a room rings for a long time. That reads
    /// as poor signal-to-noise and blanks most of the trace.
    ///
    /// The recording continues for seconds after the test signal ends, so its tail is genuine
    /// ambient noise.
    static func deconvolvedNoise(recording: [Float], stimulus: SweepStimulus,
                                 length: Int, avoiding measured: Range<Int>) -> [Float] {
        let tailStart = Swift.max(measured.upperBound, recording.count - length)
        guard recording.count - tailStart > Int(0.2 * stimulus.config.sampleRate) else {
            return []
        }
        return linearConvolve(Array(recording[tailStart...]), stimulus.inverseFilter)
    }

    /// Compare the measured interval between the two chirps with the interval they were
    /// generated at. A difference means the playback and capture clocks are running at
    /// slightly different rates.
    static func estimateClockDrift(recording: [Float], stimulus: SweepStimulus,
                                   firstChirpAt: Int) -> Double? {
        let searchFrom = firstChirpAt + stimulus.chirpToChirp - Int(0.5 * stimulus.config.sampleRate)
        guard searchFrom > 0, searchFrom < recording.count else { return nil }
        let tail = Array(recording[searchFrom...])
        guard let offset = findChirp(in: tail, reference: stimulus.chirp) else { return nil }

        let measured = (searchFrom + offset) - firstChirpAt
        let expected = stimulus.chirpToChirp
        guard expected > 0 else { return nil }
        return (Double(measured - expected) / Double(expected)) * 1e6
    }
}
