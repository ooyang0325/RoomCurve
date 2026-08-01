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
    /// Where the data came from, when it is a real measurement.
    public var source: String?
    /// Anything a user needs to know before trusting it.
    public var notes: String?

    public init(id: UUID = UUID(), name: String, points: [CurvePoint],
                isEstimate: Bool = false, source: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.points = points.sorted { $0.frequency < $1.frequency }
        self.isEstimate = isEstimate
        self.source = source
        self.notes = notes
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
        if let source { out += "# Source: \(source)\n" }
        if let notes {
            for line in notes.split(separator: "\n") { out += "# \(line)\n" }
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

    /// iPhone 17 Pro, bottom microphone, measured in an anechoic chamber.
    ///
    /// Digitised from Faber Acoustical's published measurement, made against a PCB 378B02
    /// reference microphone and corrected with its factory free-field calibration:
    /// <https://www.faberacoustical.com/blog/2025/ios/iphone/measured-iphone-17-pro-microphone-frequency-response-and-directivity/>
    ///
    /// The free-field curve is the right one here: a room measurement points the phone at the
    /// loudspeaker, so the direct sound arrives on axis. Below about 2 kHz the free-field and
    /// pressure curves are identical anyway, and that is the range room correction actually
    /// works in.
    ///
    /// Two things worth knowing before trusting the extremes:
    ///
    /// The low end rolls off considerably more than the folklore suggests — not a gentle
    /// slide below 60 Hz but −3.5 dB already at 50 Hz and −15 dB at 20 Hz. Correcting for it
    /// genuinely changes what a bass measurement says.
    ///
    /// Above 10 kHz the curve has a violent port resonance, and the same measurement's polar
    /// data shows the response there swinging by roughly 18 dB with angle. That correction is
    /// only meaningful with the microphone actually pointed at the source, and is close to
    /// meaningless if the phone is held at an angle. It is included for completeness; room
    /// correction rarely has any business up there.
    ///
    /// Values are read off a published graph, so treat them as good to a few tenths of a dB
    /// rather than exact.
    static let iPhone17Pro = MicrophoneCalibration(
        name: "iPhone 17 Pro (measured, free field)",
        points: [
            CurvePoint(frequency: 20, gainDB: -15.2),
            CurvePoint(frequency: 22, gainDB: -12.4),
            CurvePoint(frequency: 25, gainDB: -10.5),
            CurvePoint(frequency: 28, gainDB: -8.6),
            CurvePoint(frequency: 31.5, gainDB: -7.0),
            CurvePoint(frequency: 35, gainDB: -6.0),
            CurvePoint(frequency: 40, gainDB: -5.0),
            CurvePoint(frequency: 45, gainDB: -4.2),
            CurvePoint(frequency: 50, gainDB: -3.5),
            CurvePoint(frequency: 63, gainDB: -2.4),
            CurvePoint(frequency: 80, gainDB: -1.7),
            CurvePoint(frequency: 100, gainDB: -1.35),
            CurvePoint(frequency: 125, gainDB: -1.1),
            CurvePoint(frequency: 160, gainDB: -0.9),
            CurvePoint(frequency: 200, gainDB: -0.75),
            CurvePoint(frequency: 250, gainDB: -0.62),
            CurvePoint(frequency: 315, gainDB: -0.5),
            CurvePoint(frequency: 400, gainDB: -0.4),
            CurvePoint(frequency: 500, gainDB: -0.32),
            CurvePoint(frequency: 630, gainDB: -0.25),
            CurvePoint(frequency: 800, gainDB: -0.16),
            CurvePoint(frequency: 1_000, gainDB: -0.05),
            CurvePoint(frequency: 1_250, gainDB: 0.10),
            CurvePoint(frequency: 1_600, gainDB: 0.30),
            CurvePoint(frequency: 2_000, gainDB: 0.45),
            CurvePoint(frequency: 2_500, gainDB: 0.75),
            CurvePoint(frequency: 3_150, gainDB: 1.05),
            CurvePoint(frequency: 4_000, gainDB: 1.35),
            CurvePoint(frequency: 5_000, gainDB: 1.55),
            CurvePoint(frequency: 6_300, gainDB: 1.60),
            CurvePoint(frequency: 8_000, gainDB: 1.75),
            CurvePoint(frequency: 9_000, gainDB: 1.50),
            CurvePoint(frequency: 10_000, gainDB: 0.90),
            CurvePoint(frequency: 10_500, gainDB: 0.50),
            CurvePoint(frequency: 11_200, gainDB: 11.60),
            CurvePoint(frequency: 12_000, gainDB: 8.50),
            CurvePoint(frequency: 12_800, gainDB: 6.10),
            CurvePoint(frequency: 13_800, gainDB: 9.20),
            CurvePoint(frequency: 14_500, gainDB: 5.00),
            CurvePoint(frequency: 15_600, gainDB: -3.30),
            CurvePoint(frequency: 16_200, gainDB: 2.00),
            CurvePoint(frequency: 17_000, gainDB: -6.00),
            CurvePoint(frequency: 18_000, gainDB: -8.50),
            CurvePoint(frequency: 19_000, gainDB: -9.50),
            CurvePoint(frequency: 20_000, gainDB: -18.00)
        ],
        isEstimate: false,
        source: "Faber Acoustical, anechoic measurement, September 2025",
        notes: "Bottom microphone, free-field corrected. On the 17 Pro this microphone sits on "
             + "the opposite side of the USB-C port from earlier iPhones. Above 10 kHz the "
             + "response depends heavily on which way the phone points.")

    /// A starting-point correction for a built-in iPhone or iPad microphone.
    ///
    /// **This is an estimate, not a measurement.** Use a measured curve for your own model if
    /// one exists, or derive one with `derive(reference:microphone:)`. The shape here follows
    /// what is documented in general terms — reasonably flat through the midrange, rolling off
    /// below roughly 60 Hz and above roughly 16 kHz — with a first-order slope consistent with
    /// typical MEMS capsule behaviour.
    ///
    /// Note that the one iPhone model with published anechoic data rolls off substantially
    /// more at the bottom than this estimate assumes, so treat it as conservative.
    static let builtInEstimate = MicrophoneCalibration(
        name: "Built-in microphone (generic estimate)",
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

    /// Calibrations shipped with the app.
    ///
    /// Deliberately not auto-selected from the device model. Applying the wrong curve is worse
    /// than applying none, and a hardware identifier table would be guesswork for every model
    /// nobody has measured yet. The user picks; the list says plainly which entries are
    /// measured and which are estimates.
    static let bundled: [MicrophoneCalibration] = [.none, .iPhone17Pro, .builtInEstimate]
}
