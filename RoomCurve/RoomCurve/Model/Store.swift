import Foundation
import RoomCurveKit

/// A measurement saved to disk.
struct SavedMeasurement: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let modified: Date

    func load() throws -> ImpulseResponse {
        try ImpulseResponse.fromWAV(Data(contentsOf: url))
    }
}

/// Everything the app keeps on disk.
///
/// Files live in the app's Documents folder, which is exposed to the Files app, so measurements
/// and curves can be moved to iCloud, a Mac, or another tool without an export step. The
/// formats are the ones other measurement tools already read: impulse responses as 32-bit float
/// WAV, curves and calibrations as the usual two-column text.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var measurements: [SavedMeasurement] = []
    @Published private(set) var targetCurves: [TargetCurve] = []
    @Published private(set) var calibrations: [MicrophoneCalibration] = []

    private let root: URL
    private let measurementsDirectory: URL
    private let curvesDirectory: URL
    private let calibrationsDirectory: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask)[0]
        self.root = base
        measurementsDirectory = base.appendingPathComponent("Measurements", isDirectory: true)
        curvesDirectory = base.appendingPathComponent("Curves", isDirectory: true)
        calibrationsDirectory = base.appendingPathComponent("Calibrations", isDirectory: true)
        for directory in [measurementsDirectory, curvesDirectory, calibrationsDirectory] {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        }
        reload()
    }

    func reload() {
        measurements = loadMeasurements()
        targetCurves = TargetCurve.bundled + loadCurves()
        calibrations = MicrophoneCalibration.bundled + loadCalibrations()
    }

    // MARK: - Measurements

    @discardableResult
    func save(_ ir: ImpulseResponse, name: String) throws -> URL {
        let url = measurementsDirectory
            .appendingPathComponent(sanitised(name))
            .appendingPathExtension("wav")
        try ir.wavData().write(to: url, options: .atomic)
        reload()
        return url
    }

    func delete(_ measurement: SavedMeasurement) {
        try? FileManager.default.removeItem(at: measurement.url)
        reload()
    }

    func measurementExists(named name: String) -> Bool {
        measurements.contains { $0.name == sanitised(name) }
    }

    private func loadMeasurements() -> [SavedMeasurement] {
        contents(of: measurementsDirectory, extension: "wav").map {
            SavedMeasurement(url: $0.url, name: $0.url.deletingPathExtension().lastPathComponent,
                             modified: $0.modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    // MARK: - Curves

    func save(_ curve: TargetCurve) throws {
        let url = curvesDirectory
            .appendingPathComponent(sanitised(curve.name))
            .appendingPathExtension("txt")
        try curve.serialised().write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    func delete(curve: TargetCurve) {
        guard !curve.isBuiltIn else { return }
        let url = curvesDirectory
            .appendingPathComponent(sanitised(curve.name))
            .appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// Import a curve or calibration file chosen from the Files app.
    @discardableResult
    func importCurve(from source: URL, asCalibration: Bool = false) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let text = try String(contentsOf: source, encoding: .utf8)
        let name = source.deletingPathExtension().lastPathComponent
        let directory = asCalibration ? calibrationsDirectory : curvesDirectory

        if asCalibration {
            guard MicrophoneCalibration.parse(text, name: name) != nil else {
                throw StoreError.unreadableCurve
            }
        } else {
            guard TargetCurve.parse(text, name: name) != nil else {
                throw StoreError.unreadableCurve
            }
        }

        let destination = directory.appendingPathComponent(sanitised(name))
            .appendingPathExtension("txt")
        try text.write(to: destination, atomically: true, encoding: .utf8)
        reload()
        return name
    }

    private func loadCurves() -> [TargetCurve] {
        contents(of: curvesDirectory, extension: "txt").compactMap {
            guard let text = try? String(contentsOf: $0.url, encoding: .utf8) else { return nil }
            return TargetCurve.parse(text,
                                     name: $0.url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Calibrations

    func save(_ calibration: MicrophoneCalibration) throws {
        let url = calibrationsDirectory
            .appendingPathComponent(sanitised(calibration.name))
            .appendingPathExtension("txt")
        try calibration.serialised().write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    func delete(calibration: MicrophoneCalibration) {
        let url = calibrationsDirectory
            .appendingPathComponent(sanitised(calibration.name))
            .appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    private func loadCalibrations() -> [MicrophoneCalibration] {
        contents(of: calibrationsDirectory, extension: "txt").compactMap {
            guard let text = try? String(contentsOf: $0.url, encoding: .utf8) else { return nil }
            return MicrophoneCalibration.parse(
                text, name: $0.url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Scratch files for export

    /// Write a file to a temporary location for sharing.
    func temporaryFile(named name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, options: .atomic)
        return url
    }

    func temporaryFile(named name: String, text: String) throws -> URL {
        try temporaryFile(named: name, contents: Data(text.utf8))
    }

    // MARK: - Helpers

    private func contents(of directory: URL, extension ext: String)
        -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == ext }.map {
            let date = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return ($0, date)
        }
    }

    private func sanitised(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

enum StoreError: Error, LocalizedError {
    case unreadableCurve

    var errorDescription: String? {
        switch self {
        case .unreadableCurve:
            "That file does not look like a curve. Expected lines of frequency and gain, "
            + "for example \"20  6.0\"."
        }
    }
}
