import Testing
import Foundation
@testable import RoomCurveKit

/// The backstop: a synthetic room is measured through the complete pipeline and the result is
/// checked against what the room actually is. A break anywhere — sweep generation, the inverse
/// filter, deconvolution, windowing, the FFT, grid resampling, smoothing — shows up here.
@Suite("End to end")
struct EndToEndTests {

    /// A room with a couple of modal resonances and a low-frequency rolloff, rendered as an
    /// impulse response by running an impulse through the filter cascade.
    func syntheticRoom(_ filters: [Biquad], length: Int = 8_192,
                       sampleRate: Double = 48_000) -> [Float] {
        var signal = [Float](repeating: 0, count: length)
        signal[0] = 1

        for filter in filters {
            let c = filter.coefficients(sampleRate: sampleRate)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<length {
                let x = Double(signal[i])
                let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                signal[i] = Float(y)
            }
        }
        return signal
    }

    func convolve(_ signal: [Float], _ ir: [Float]) -> [Float] {
        Deconvolver.linearConvolve(signal, ir)
    }

    @Test("measures a synthetic room and recovers its actual response")
    func measuresKnownRoom() throws {
        let room = [
            Biquad(type: .peaking, frequency: 62, gainDB: 10, q: 5),
            Biquad(type: .peaking, frequency: 145, gainDB: -7, q: 4),
            Biquad(type: .peaking, frequency: 400, gainDB: 5, q: 2),
            Biquad(type: .highShelf, frequency: 6_000, gainDB: -4, q: 0.707)
        ]
        let config = SweepConfig(duration: 2.0, sampleRate: 48_000,
                                 preRoll: 0.5, gap: 0.3, tail: 0.5)
        let stimulus = SweepGenerator.make(config)

        // Play through the room, with a latency the analysis knows nothing about.
        let played = convolve(stimulus.samples, syntheticRoom(room))
        var recording = [Float](repeating: 0, count: 11_000)
        recording.append(contentsOf: played)

        let ir = try Deconvolver.analyse(recording: recording, stimulus: stimulus)
        let measured = Analyser.response(of: ir).smoothed(.oct1_6)

        // Compare against the room's true response, both normalised at 1 kHz since the
        // deconvolution carries an arbitrary overall gain.
        let grid = measured.grid
        let truth = room.combinedResponseDB(on: grid)
        let at1k = Int(grid.index(of: 1_000).rounded())
        let offset = measured.magnitudeDB[at1k] - truth[at1k]

        for i in grid.indices(from: 40, to: 12_000) {
            let error = (measured.magnitudeDB[i] - offset) - truth[i]
            #expect(abs(error) < 3.0)
        }

        // The resonances must land at the right frequencies, not merely somewhere.
        let at62 = Int(grid.index(of: 62).rounded())
        let at145 = Int(grid.index(of: 145).rounded())
        #expect(measured.magnitudeDB[at62] - offset > 6)
        #expect(measured.magnitudeDB[at145] - offset < -4)
    }

    @Test("full path: measure, equalise, export, and the correction is real")
    func measureThenCorrect() throws {
        let room = [
            Biquad(type: .peaking, frequency: 55, gainDB: 11, q: 4),
            Biquad(type: .peaking, frequency: 130, gainDB: -6, q: 3),
            Biquad(type: .peaking, frequency: 300, gainDB: 6, q: 2.5)
        ]
        let config = SweepConfig(duration: 2.0, sampleRate: 48_000,
                                 preRoll: 0.5, gap: 0.3, tail: 0.5)
        let stimulus = SweepGenerator.make(config)
        let played = convolve(stimulus.samples, syntheticRoom(room))
        var recording = [Float](repeating: 0, count: 7_500)
        recording.append(contentsOf: played)

        let ir = try Deconvolver.analyse(recording: recording, stimulus: stimulus)
        let measured = Analyser.response(of: ir).smoothed(.variable)
        let grid = measured.grid

        // Fit a flat target to the measurement, the way the app does.
        let target = TargetCurve.bundled.first { $0.name == "Flat" }!.sampled(on: grid)
        let blanked = measured.blanked(belowSNR: 10)
        let offset = TargetCurve.fitOffset(target: target, measured: measured.magnitudeDB,
                                           blanked: blanked,
                                           range: grid.indices(from: 30, to: 500))
        let fittedTarget = target.map { $0 + offset }

        let correction = AutoEQ.correct(measuredDB: measured.magnitudeDB,
                                        targetDB: fittedTarget,
                                        snrDB: measured.snrDB,
                                        settings: EQSettings(minFrequency: 30,
                                                             maxFrequency: 500,
                                                             maxFilters: 8))
        #expect(!correction.filters.isEmpty)

        // The correction must actually flatten things.
        let range = grid.indices(from: 40, to: 450)
        func spread(_ values: [Double]) -> Double {
            let inRange = range.map { values[$0] - fittedTarget[$0] }
            let mean = inRange.reduce(0, +) / Double(inRange.count)
            return (inRange.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
                    / Double(inRange.count)).squareRoot()
        }
        let before = spread(measured.magnitudeDB)
        let after = spread(correction.predictedDB)
        #expect(after < before * 0.5)

        // And it must survive the trip out to a file and back.
        let set = FilterSet(title: "End to end", preampDB: correction.preampDB,
                            filters: correction.filters)
        let restored = try FilterSet.fromJSON(set.toJSON())
        let originalResponse = set.active.combinedResponseDB(on: grid)
        let restoredResponse = restored.active.combinedResponseDB(on: grid)
        for i in 0..<grid.count {
            #expect(abs(originalResponse[i] - restoredResponse[i]) < 1e-9)
        }
    }

    @Test("averaging several positions suppresses position-specific nulls")
    func averagingAcrossPositions() {
        let grid = LogGrid.standard
        func responseAt(nullFrequency: Double) -> FrequencyResponse {
            let filters = [Biquad(type: .peaking, frequency: nullFrequency,
                                  gainDB: -20, q: 12)]
            return FrequencyResponse(
                grid: grid,
                magnitudeDB: filters.combinedResponseDB(on: grid),
                phaseDegrees: [Double](repeating: 0, count: grid.count),
                groupDelayMS: [Double](repeating: 0, count: grid.count),
                snrDB: [Double](repeating: 60, count: grid.count))
        }

        // Each seat has a deep null, but at a different frequency.
        let seats = [78.0, 91.0, 105.0, 120.0].map(responseAt)
        let averaged = FrequencyResponse.average(seats)!

        // No single null survives at full depth — which is the entire reason for averaging
        // before equalising.
        for frequency in [78.0, 91.0, 105.0, 120.0] {
            let i = Int(grid.index(of: frequency).rounded())
            #expect(averaged.magnitudeDB[i] > -13)
        }
    }

    @Test("a calibration measured on one device corrects that device")
    func calibrationLoop() throws {
        // The full open-calibration story: measure a speaker with a reference microphone and
        // again with the built-in one, derive the difference, and check it recovers the truth.
        let speaker = [Biquad(type: .peaking, frequency: 800, gainDB: 6, q: 2)]
        let grid = LogGrid.standard

        func measurement(extra: [Biquad]) throws -> FrequencyResponse {
            let config = SweepConfig(duration: 2.0, sampleRate: 48_000,
                                     preRoll: 0.5, gap: 0.3, tail: 0.5)
            let stimulus = SweepGenerator.make(config)
            let played = convolve(stimulus.samples, syntheticRoom(speaker + extra))
            var recording = [Float](repeating: 0, count: 6_000)
            recording.append(contentsOf: played)
            let ir = try Deconvolver.analyse(recording: recording, stimulus: stimulus)
            return Analyser.response(of: ir).smoothed(.oct1_6)
        }

        // The phone's microphone rolls the bottom off; the reference microphone does not.
        let phoneDefect = [Biquad(type: .lowShelf, frequency: 80, gainDB: -8, q: 0.707)]
        let reference = try measurement(extra: [])
        let phone = try measurement(extra: phoneDefect)

        let calibration = MicrophoneCalibration.derive(reference: reference, microphone: phone,
                                                       name: "Synthetic phone")
        let corrected = phone.applying(calibrationDB: calibration.sampled(on: grid))

        let at1k = Int(grid.index(of: 1_000).rounded())
        let offset = corrected.magnitudeDB[at1k] - reference.magnitudeDB[at1k]
        for i in grid.indices(from: 40, to: 10_000) {
            let error = (corrected.magnitudeDB[i] - offset) - reference.magnitudeDB[i]
            #expect(abs(error) < 1.5)
        }
    }
}
