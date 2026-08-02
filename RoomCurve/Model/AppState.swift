import Combine
import Foundation
import SwiftUI
import RoomCurveKit

/// Which plot is on screen.
enum PlotKind: String, CaseIterable, Identifiable {
    case magnitude, phase, groupDelay
    var id: String { rawValue }

    var label: String {
        switch self {
        case .magnitude: "Magnitude"
        case .phase: "Phase"
        case .groupDelay: "Group Delay"
        }
    }

    var unit: String {
        switch self {
        case .magnitude: "dB"
        case .phase: "°"
        case .groupDelay: "ms"
        }
    }
}

/// How captured sweeps are combined on screen.
enum PlotMode: String, CaseIterable, Identifiable {
    /// Running average — for tuning towards a target curve.
    case average
    /// Latest on top of previous — for seeing what an adjustment did.
    case history
    var id: String { rawValue }

    var label: String {
        switch self {
        case .average: "Average"
        case .history: "History"
        }
    }
}

/// Settings and captured data, shared across the app.
@MainActor
final class AppState: ObservableObject {

    // Measurement
    @Published var sweepConfig = SweepConfig()
    @Published var removeDelay = true
    @Published var externalStimulus = false
    @Published var chirpChannel: OutputChannel = .both
    @Published var sweepChannel: OutputChannel = .both
    @Published var realTimeChannel: OutputChannel = .both

    // Plotting
    @Published var smoothing: Smoothing = .variable
    @Published var plotMode: PlotMode = .average
    @Published var realTimeMode: RealTimeAnalyser.Mode = .live
    @Published var snrThreshold: Double = 10
    @Published var blankingEnabled = true
    /// Drawn on the measurement screens for reference. Does not affect correction.
    @Published var referenceTargetName = "Classic tilt (−1 dB/oct)"
    @Published var curveFit: CurveFit = .automatic
    @Published var comparisonMeasurement: SavedMeasurement?

    // Microphone
    @Published var calibrationName = "None"
    @Published var applyCalibration = true

    // Equalisation
    @Published var eqSettings = EQSettings()
    /// The curve correction is actually calculated against, chosen on the Equalize screen.
    @Published var eqTargetName = "Classic tilt (−1 dB/oct)"

    // Captured this session
    @Published var captures: [FrequencyResponse] = []
    @Published var lastImpulseResponse: ImpulseResponse?
    @Published var lastClockDriftPPM: Double?
    @Published var status: String?
    @Published var errorMessage: String?

    let grid = LogGrid.standard

    // MARK: - Derived

    /// The measurement being displayed and equalised.
    var currentResponse: FrequencyResponse? {
        guard !captures.isEmpty else { return nil }
        let combined = plotMode == .average
            ? FrequencyResponse.average(captures)
            : captures.last
        return combined?.smoothed(smoothing)
    }

    func targetCurve(named name: String, from store: Store) -> TargetCurve {
        store.targetCurves.first { $0.name == name } ?? TargetCurve.bundled[0]
    }

    func calibration(from store: Store) -> MicrophoneCalibration? {
        guard applyCalibration else { return nil }
        return store.calibrations.first { $0.name == calibrationName }
    }

    /// Reference target curve sampled and positioned against the current measurement.
    func fittedTarget(from store: Store) -> [Double] {
        let target = targetCurve(named: referenceTargetName, from: store).sampled(on: grid)
        guard let response = currentResponse else {
            if case .manual(let level) = curveFit { return target.map { $0 + level } }
            return target
        }
        switch curveFit {
        case .manual(let level):
            return target.map { $0 + level }
        case .automatic:
            let offset = TargetCurve.fitOffset(
                target: target, measured: response.magnitudeDB,
                blanked: blanked(for: response),
                range: grid.indices(from: 20, to: 20_000))
            return target.map { $0 + offset }
        }
    }

    func blanked(for response: FrequencyResponse) -> [Bool] {
        blankingEnabled ? response.blanked(belowSNR: snrThreshold)
                        : [Bool](repeating: false, count: grid.count)
    }

    /// Apply microphone calibration to a freshly measured response.
    func calibrated(_ response: FrequencyResponse, store: Store) -> FrequencyResponse {
        guard let calibration = calibration(from: store) else { return response }
        return response.applying(calibrationDB: calibration.sampled(on: grid))
    }

    func addCapture(_ response: FrequencyResponse) {
        captures.append(response)
    }

    func undoCapture() {
        if !captures.isEmpty { captures.removeLast() }
    }

    func resetCaptures() {
        captures.removeAll()
        lastImpulseResponse = nil
        lastClockDriftPPM = nil
    }

    func show(_ message: String) {
        status = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if status == message { status = nil }
        }
    }
}
