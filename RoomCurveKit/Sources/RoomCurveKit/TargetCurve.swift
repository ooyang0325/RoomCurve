import Foundation

/// One point of a target curve.
public struct CurvePoint: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var frequency: Double
    public var gainDB: Double

    public init(id: UUID = UUID(), frequency: Double, gainDB: Double) {
        self.id = id
        self.frequency = frequency
        self.gainDB = gainDB
    }
}

/// A target curve — the shape a system is tuned towards.
public struct TargetCurve: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var points: [CurvePoint]
    /// Curves that ship with the app cannot be edited in place; editing forks a copy.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, points: [CurvePoint], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.points = points.sorted { $0.frequency < $1.frequency }
        self.isBuiltIn = isBuiltIn
    }

    /// The curve sampled onto the shared grid, in dB.
    public func sampled(on grid: LogGrid = .standard) -> [Double] {
        grid.interpolate(points: points.map { ($0.frequency, $0.gainDB) })
    }

    // MARK: - File format

    /// Parse the curve format REW, HouseCurve and most measurement tools share: one
    /// `frequency gain [phase]` per line, separated by spaces, tabs or commas. Any line that
    /// does not start with a number is a comment. A third column, if present, is phase and is
    /// ignored.
    public static func parse(_ text: String, name: String) -> TargetCurve? {
        var points: [CurvePoint] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
                .map { String($0) }
            guard fields.count >= 2,
                  let frequency = Double(fields[0]),
                  let gain = Double(fields[1]),
                  frequency > 0 else { continue }
            points.append(CurvePoint(frequency: frequency, gainDB: gain))
        }
        guard !points.isEmpty else { return nil }
        return TargetCurve(name: name, points: points)
    }

    /// Serialise back to that same format.
    public func serialised() -> String {
        var out = "# \(name)\n# Frequency (Hz)  Gain (dB)\n"
        for point in points.sorted(by: { $0.frequency < $1.frequency }) {
            out += String(format: "%.2f\t%.2f\n", point.frequency, point.gainDB)
        }
        return out
    }
}

// MARK: - Fitting

public enum CurveFit: Sendable, Equatable, Hashable {
    /// Slide the curve vertically to sit on the measurement.
    case automatic
    /// Hold the curve at a fixed level, so it stays put between measurements.
    case manual(Double)
}

public extension TargetCurve {
    /// Offset that best aligns this curve with a measurement.
    ///
    /// A plain mean of the difference, which is the least-squares answer for a pure vertical
    /// shift. Blanked frequencies are excluded — a region the measurement could not resolve
    /// should not be allowed to drag the whole target up or down.
    static func fitOffset(target: [Double], measured: [Double], blanked: [Bool],
                          range: Range<Int>) -> Double {
        var sum = 0.0
        var count = 0
        for i in range where i < target.count && i < measured.count {
            if i < blanked.count && blanked[i] { continue }
            sum += measured[i] - target[i]
            count += 1
        }
        return count > 0 ? sum / Double(count) : 0
    }
}

// MARK: - Bundled curves

public extension TargetCurve {
    /// Curves shipped with the app.
    ///
    /// Deliberately described by their shape rather than attributed to a published standard.
    /// The well-known named curves (B&K, Harman) are specific published datasets; rather than
    /// approximate them from memory and put an authoritative name on the result, the app reads
    /// the standard curve file format, so a real one can be imported.
    static let bundled: [TargetCurve] = [
        TargetCurve(name: "Flat", points: [
            CurvePoint(frequency: 20, gainDB: 0),
            CurvePoint(frequency: 20_000, gainDB: 0)
        ], isBuiltIn: true),

        TargetCurve(name: "Gentle tilt (−0.5 dB/oct)", points: [
            CurvePoint(frequency: 20, gainDB: 2.5),
            CurvePoint(frequency: 20_000, gainDB: -2.5)
        ], isBuiltIn: true),

        TargetCurve(name: "Classic tilt (−1 dB/oct)", points: [
            CurvePoint(frequency: 20, gainDB: 5),
            CurvePoint(frequency: 20_000, gainDB: -5)
        ], isBuiltIn: true),

        TargetCurve(name: "Warm (bass shelf + tilt)", points: [
            CurvePoint(frequency: 20, gainDB: 8),
            CurvePoint(frequency: 60, gainDB: 6),
            CurvePoint(frequency: 200, gainDB: 2),
            CurvePoint(frequency: 1_000, gainDB: 0),
            CurvePoint(frequency: 20_000, gainDB: -4)
        ], isBuiltIn: true),

        TargetCurve(name: "Car (extra bass)", points: [
            CurvePoint(frequency: 20, gainDB: 12),
            CurvePoint(frequency: 50, gainDB: 9),
            CurvePoint(frequency: 120, gainDB: 4),
            CurvePoint(frequency: 500, gainDB: 0),
            CurvePoint(frequency: 5_000, gainDB: -2),
            CurvePoint(frequency: 20_000, gainDB: -6)
        ], isBuiltIn: true)
    ]
}
