import Foundation
import Accelerate

/// Watches a growing recording for the timing chirp.
///
/// The first version of this looked for the room getting louder. That is cheap but it is not
/// specific to anything: a door, a cough, or somebody starting the wrong track all cross the
/// threshold, and the capture then starts at the wrong moment and fails several seconds later
/// with a confusing message.
///
/// This matches the chirp itself. Correlating against the known sweep is selective in a way an
/// energy threshold cannot be — the chirp's autocorrelation is a sharp spike, while broadband
/// noise or an impulse smears across the whole 200 ms and never reaches the same peak relative
/// to its own background. The cost is kept bounded by scanning only newly arrived audio in
/// blocks, rather than re-correlating a buffer that grows for as long as somebody takes to
/// walk to their laptop.
public final class ChirpDetector {
    private let reference: [Float]
    private let reversed: [Float]
    private let sampleRate: Double
    private let blockSize: Int
    private let overlap: Int
    private let threshold: Float

    /// Absolute sample index already examined.
    private var scanned = 0

    /// - Parameter threshold: how far the correlation peak must stand above the background of
    ///   the block it was found in. Chirp autocorrelation clears this comfortably; noise of the
    ///   same loudness does not come close.
    public init(reference: [Float], sampleRate: Double, threshold: Float = 12) {
        self.reference = reference
        self.reversed = [Float](reference.reversed())
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.blockSize = Swift.max(reference.count * 4, Int(sampleRate))
        self.overlap = reference.count * 2
    }

    /// Feed everything captured so far. Returns the chirp's absolute sample index once found.
    ///
    /// Safe to call repeatedly; each call only looks at audio it has not seen, plus enough of
    /// an overlap that a chirp straddling a block boundary is still caught whole.
    public func scan(_ recording: [Float]) -> Int? {
        while recording.count - scanned >= blockSize {
            let start = Swift.max(0, scanned - overlap)
            let end = Swift.min(recording.count, start + blockSize + overlap)
            let block = Array(recording[start..<end])

            if let offset = locate(in: block) {
                return start + offset
            }
            scanned += blockSize
        }
        return nil
    }

    /// Start over, for a fresh measurement.
    public func reset() { scanned = 0 }

    /// Matched-filter one block.
    private func locate(in block: [Float]) -> Int? {
        guard block.count > reference.count else { return nil }
        let correlation = Deconvolver.linearConvolve(block, reversed)
        guard let peak = Deconvolver.peakIndex(of: correlation) else { return nil }

        let rms = sqrt(vDSP.meanSquare(correlation))
        guard rms > 0 else { return nil }
        guard abs(correlation[peak]) / rms > threshold else { return nil }

        let arrival = peak - (reference.count - 1)
        return arrival >= 0 && arrival < block.count ? arrival : nil
    }
}

public extension SweepStimulus {
    /// Samples that must still arrive after the chirp is heard, before the recording holds a
    /// complete measurement — the rest of the signal, plus a margin of quiet afterwards that
    /// doubles as the noise reference.
    var samplesNeededAfterOnset: Int {
        samples.count - chirpStart + Int(1.5 * config.sampleRate)
    }
}
