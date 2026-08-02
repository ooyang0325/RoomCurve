import Foundation
import Accelerate

/// Matched filtering for the timing chirp.
///
/// The measure that matters is **sharpness**: how far the correlation peak stands above the
/// background immediately around it. Correlating a chirp with itself compresses 200 ms of sweep
/// into a spike a fraction of a millisecond wide, so the peak towers over its neighbourhood.
/// Everything else fails that test for a reason rooted in what it is:
///
/// - a trackpad or keyboard click is an impulse, so matched filtering smears it back out into
///   the shape of the chirp — 200 ms wide, with no spike;
/// - noise correlates weakly and evenly;
/// - the sweep crosses the same frequencies far more slowly, so it never compresses.
///
/// Sharpness is also scale free, which is what the previous version got wrong. Judging the peak
/// against the average level of the surrounding recording makes any small transient in a quiet
/// stretch look enormous — a click during a silent moment scored higher than a real chirp
/// played across a room.
enum ChirpMatch {

    /// Peak height against the background either side of it.
    ///
    /// - Parameter guardBand: skipped either side of the peak, so it does not measure itself.
    static func sharpness(of correlation: [Float], at index: Int,
                          span: Int, guardBand: Int) -> Float {
        let low = Swift.max(0, index - span)
        let high = Swift.min(correlation.count, index + span)
        guard high > low else { return 0 }

        var sum: Float = 0
        var count = 0
        for k in low..<high where abs(k - index) > guardBand {
            sum += correlation[k] * correlation[k]
            count += 1
        }
        guard count > 0 else { return 0 }
        let background = (sum / Float(count)).squareRoot()
        guard background > 0 else { return 0 }
        return abs(correlation[index]) / background
    }

    /// Find where a chirp arrives in `signal`, if it does at all.
    ///
    /// - Parameter earliest: take the first arrival that passes rather than the sharpest. The
    ///   stimulus deliberately ends with a second, identical chirp, and a strong early
    ///   reflection can outrank the direct sound; the first qualifying peak is the one that
    ///   defines t=0.
    static func arrival(of reference: [Float], in signal: [Float],
                        sampleRate: Double, threshold: Float,
                        earliest: Bool = true) -> (index: Int, sharpness: Float)? {
        guard signal.count > reference.count else { return nil }
        let correlation = Deconvolver.linearConvolve(signal, [Float](reference.reversed()))
        let guardBand = Swift.max(1, Int(0.002 * sampleRate))
        let span = reference.count

        // Scan in windows, so a later and louder chirp cannot hide an earlier one.
        var best: (index: Int, sharpness: Float)?
        var position = 0
        while position < correlation.count {
            let end = Swift.min(position + span, correlation.count)
            var peak = position
            for k in position..<end where abs(correlation[k]) > abs(correlation[peak]) {
                peak = k
            }
            position = end

            let score = sharpness(of: correlation, at: peak, span: span, guardBand: guardBand)
            guard score > threshold else { continue }

            let arrival = peak - (reference.count - 1)
            guard arrival >= 0 else { continue }
            if earliest { return (arrival, score) }
            if best == nil || score > best!.sharpness { best = (arrival, score) }
        }
        return best
    }
}

/// Watches a growing recording for the timing chirp.
///
/// Listens for as long as it takes — somebody has to reach whatever is playing the file and
/// press play — while keeping the work bounded by only examining audio it has not seen yet.
public final class ChirpDetector {
    private let reference: [Float]
    private let sampleRate: Double
    private let blockSize: Int
    private let overlap: Int
    private let threshold: Float
    private var scanned = 0

    /// - Parameter threshold: minimum sharpness. Real chirps measure in the tens even across a
    ///   room; clicks, noise and the sweep itself sit around two or three.
    public init(reference: [Float], sampleRate: Double, threshold: Float = 12) {
        self.reference = reference
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.blockSize = Swift.max(reference.count * 4, Int(sampleRate))
        self.overlap = reference.count * 2
    }

    /// Feed everything captured so far. Returns the chirp's absolute sample index once found.
    public func scan(_ recording: [Float]) -> Int? {
        while recording.count - scanned >= blockSize {
            let start = Swift.max(0, scanned - overlap)
            let end = Swift.min(recording.count, start + blockSize + overlap)

            if let found = ChirpMatch.arrival(of: reference, in: Array(recording[start..<end]),
                                              sampleRate: sampleRate, threshold: threshold) {
                return start + found.index
            }
            scanned += blockSize
        }
        return nil
    }

    public func reset() { scanned = 0 }
}

public extension SweepStimulus {
    /// Samples that must still arrive after the chirp is heard before the recording holds a
    /// complete measurement.
    ///
    /// Deliberately generous. Capture is cheap, and leaving the analysis room either side of
    /// what it strictly needs means a slightly early or late detection still has a complete
    /// measurement inside the buffer, rather than one clipped at the end.
    var samplesNeededAfterOnset: Int {
        samples.count - chirpStart + Int(2.5 * config.sampleRate)
    }
}
