import Foundation

/// A microphone calibration: the microphone's own deviation from flat, in dB.
///
/// Stored in the same text format as target curves, because it is the same format every
/// measurement tool uses for calibration files — so a UMIK-1 or iMM-6 file downloaded from the
/// manufacturer drops straight in.
///
/// Sign convention follows those files: a negative value means the capsule reads *low* at that
/// frequency, so the measurement gets raised by that amount.
public struct MicrophoneCalibration: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var points: [CurvePoint]
    /// True when this is a shipped estimate rather than a measurement of a real microphone.
    public var isEstimate: Bool

    public init(id: UUID = UUID(), name: String, points: [CurvePoint],
                isEstimate: Bool = false) {
        self.id = id
        self.name = name
        self.points = points.sorted { $0.frequency < $1.frequency }
        self.isEstimate = isEstimate
    }

    public func sampled(on grid: LogGrid = .standard) -> [Double] {
        grid.interpolate(points: points.map { ($0.frequency, $0.gainDB) })
    }

    public static func parse(_ text: String, name: String,
                             isEstimate: Bool = false) -> MicrophoneCalibration? {
        guard let curve = TargetCurve.parse(text, name: name) else { return nil }
        return MicrophoneCalibration(name: name, points: curve.points, isEstimate: isEstimate)
    }

    public func serialised() -> String {
        var out = "# \(name)\n"
        if isEstimate {
            out += "# ESTIMATE — not measured against a reference microphone.\n"
        }
        out += "# Microphone deviation from flat. Negative means the microphone reads low\n"
        out += "# at that frequency, so measurements are raised by this amount.\n"
        out += "# Frequency (Hz)  Deviation (dB)\n"
        for point in points {
            out += String(format: "%.2f\t%.2f\n", point.frequency, point.gainDB)
        }
        return out
    }
}

public extension MicrophoneCalibration {

    /// Derive a calibration for one microphone by comparing it against a reference microphone.
    ///
    /// Measure a speaker with a calibrated reference microphone, then measure the same speaker
    /// from the same position with the microphone being calibrated. Whatever differs between
    /// the two measurements is the second microphone, because everything else was held
    /// constant. Normalised to 0 dB at 1 kHz, since only the shape matters.
    ///
    /// This exists because there is no published calibration curve for any iPhone model, from
    /// Apple or anyone else. The paid apps in this space bake in an unpublished generic
    /// correction. An open project can do better: let people measure their own device and share
    /// the file.
    static func derive(reference: FrequencyResponse,
                       microphone: FrequencyResponse,
                       name: String,
                       grid: LogGrid = .standard,
                       smoothing: Smoothing = .oct1_6,
                       snrThreshold: Double = 10) -> MicrophoneCalibration {
        let referenceSmoothed = reference.smoothed(smoothing).magnitudeDB
        let microphoneSmoothed = microphone.smoothed(smoothing).magnitudeDB

        var deviation = (0..<grid.count).map { microphoneSmoothed[$0] - referenceSmoothed[$0] }

        // Only the shape is meaningful; the two measurements were at different absolute levels.
        let at1k = Int(grid.index(of: 1_000).rounded())
        let offset = at1k < deviation.count ? deviation[at1k] : 0
        for i in deviation.indices { deviation[i] -= offset }

        // Where either measurement was too noisy to trust, hold the last good value rather
        // than writing noise into the calibration file.
        var lastGood = 0.0
        for i in deviation.indices {
            let usable = i < reference.snrDB.count && i < microphone.snrDB.count
                && reference.snrDB[i] >= snrThreshold && microphone.snrDB[i] >= snrThreshold
            if usable { lastGood = deviation[i] } else { deviation[i] = lastGood }
        }

        // One point per sixth of an octave is plenty for a calibration file and keeps it
        // readable by a human.
        let stride = Swift.max(1, Int(grid.pointsPerOctave / 6))
        var points: [CurvePoint] = []
        for i in Swift.stride(from: 0, to: grid.count, by: stride) {
            points.append(CurvePoint(frequency: (grid.frequencies[i] * 100).rounded() / 100,
                                     gainDB: (deviation[i] * 100).rounded() / 100))
        }
        return MicrophoneCalibration(name: name, points: points, isEstimate: false)
    }

    /// A starting-point correction for a built-in iPhone or iPad microphone.
    ///
    /// **This is an estimate, not a measurement.** No manufacturer or third party publishes a
    /// frequency response for any iPhone microphone. What is documented is only the shape: the
    /// response is reasonably flat through the midrange and rolls off below roughly 60 Hz and
    /// above roughly 16 kHz. The numbers here follow a first-order rolloff consistent with that
    /// description and with typical MEMS capsule behaviour.
    ///
    /// It ships as an editable file, and is marked as an estimate everywhere it appears, so it
    /// can be replaced by a real one from `derive(reference:microphone:)`.
    static let builtInEstimate = MicrophoneCalibration(
        name: "Built-in microphone (estimate)",
        points: [
            CurvePoint(frequency: 20, gainDB: -12.0),
            CurvePoint(frequency: 25, gainDB: -9.5),
            CurvePoint(frequency: 31.5, gainDB: -7.0),
            CurvePoint(frequency: 40, gainDB: -4.5),
            CurvePoint(frequency: 50, gainDB: -2.5),
            CurvePoint(frequency: 63, gainDB: -1.2),
            CurvePoint(frequency: 80, gainDB: -0.5),
            CurvePoint(frequency: 100, gainDB: 0.0),
            CurvePoint(frequency: 1_000, gainDB: 0.0),
            CurvePoint(frequency: 10_000, gainDB: 0.0),
            CurvePoint(frequency: 12_500, gainDB: -0.5),
            CurvePoint(frequency: 16_000, gainDB: -1.5),
            CurvePoint(frequency: 18_000, gainDB: -3.0),
            CurvePoint(frequency: 20_000, gainDB: -5.0)
        ],
        isEstimate: true)

    /// No correction at all.
    static let none = MicrophoneCalibration(
        name: "None",
        points: [CurvePoint(frequency: 20, gainDB: 0), CurvePoint(frequency: 20_000, gainDB: 0)],
        isEstimate: false)
}
