import Foundation
import Accelerate

/// Finds the moment a test signal starts inside a recording that is still growing.
///
/// External stimulus means somebody else plays the signal — from a laptop, a streamer, a USB
/// stick in a car — and the app has no idea when that will be. Recording for a fixed window and
/// hoping the two overlap turns the feature into a race against a stopwatch. Watching for the
/// signal instead means the phone simply waits, however long it takes.
///
/// Detection is by energy rather than by correlating against the chirp: it is cheap enough to
/// run several times a second on a buffer that keeps growing, and the exported signal opens
/// with silence, so the first thing to rise above the room's noise floor *is* the chirp.
public enum SignalOnset {

    /// Index of the first block that rises clearly above the recording's own noise floor.
    ///
    /// - Parameters:
    ///   - reference: how much of the start of the recording is assumed to be silence, and used
    ///     to establish what "quiet" means in this room.
    ///   - threshold: how far above that floor counts as the signal, in dB.
    /// - Returns: a sample index, or nil while nothing has stood out yet.
    public static func find(in recording: [Float],
                            sampleRate: Double,
                            blockSeconds: Double = 0.02,
                            reference: Double = 0.5,
                            threshold: Double = 12) -> Int? {
        let blockSize = Swift.max(64, Int(blockSeconds * sampleRate))
        let blockCount = recording.count / blockSize
        guard blockCount > 4 else { return nil }

        var levels = [Float](repeating: 0, count: blockCount)
        for b in 0..<blockCount {
            let slice = Array(recording[(b * blockSize)..<((b + 1) * blockSize)])
            levels[b] = sqrt(vDSP.meanSquare(slice))
        }

        // The floor is the median of the opening blocks, not the mean: a single click or a door
        // closing during the reference window would drag a mean up and mask the real signal.
        let referenceBlocks = Swift.max(3, Swift.min(blockCount / 2,
                                                     Int(reference / blockSeconds)))
        let floor = median(Array(levels[0..<referenceBlocks]))

        // Never trust an absolutely silent reference — in a digitally silent recording every
        // block would "exceed" a floor of zero.
        let limit = Swift.max(floor * Float(linear(fromDB: threshold)), 1e-5)

        for b in referenceBlocks..<blockCount where levels[b] > limit {
            return b * blockSize
        }
        return nil
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

public extension SweepStimulus {
    /// Samples that must still arrive after the signal starts, before the recording holds a
    /// complete measurement.
    ///
    /// The exported file opens with silence, so detection fires at the chirp — everything from
    /// there to the end of the file is still to come, plus a margin of quiet afterwards that
    /// doubles as the noise reference.
    var samplesNeededAfterOnset: Int {
        let preRoll = Int(config.preRoll * config.sampleRate)
        let margin = Int(1.5 * config.sampleRate)
        return samples.count - preRoll + margin
    }
}
