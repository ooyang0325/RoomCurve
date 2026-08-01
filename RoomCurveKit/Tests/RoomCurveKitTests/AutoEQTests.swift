import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Target curves")
struct TargetCurveTests {

    @Test("parses the standard curve file format")
    func parsing() throws {
        let text = """
        # A comment line
        Hz  dB
        20      6.0
        200,    2.0
        2000\t0.0
        20000   -4.0  0.0
        """
        let curve = try #require(TargetCurve.parse(text, name: "Test"))
        #expect(curve.points.count == 4)
        #expect(curve.points[0].frequency == 20)
        #expect(curve.points[0].gainDB == 6)
        // The third column is phase and must be ignored, not treated as a gain.
        #expect(curve.points[3].gainDB == -4)
    }

    @Test("rejects a file with no numeric rows")
    func parsingEmpty() {
        #expect(TargetCurve.parse("# nothing here\nHz dB\n", name: "x") == nil)
    }

    @Test("round trips through serialisation")
    func roundTrip() throws {
        let original = TargetCurve(name: "Round trip", points: [
            CurvePoint(frequency: 20, gainDB: 5),
            CurvePoint(frequency: 1_000, gainDB: 0),
            CurvePoint(frequency: 20_000, gainDB: -5)
        ])
        let reparsed = try #require(TargetCurve.parse(original.serialised(), name: "Round trip"))
        #expect(reparsed.points.count == 3)
        for (a, b) in zip(original.points, reparsed.points) {
            #expect(abs(a.frequency - b.frequency) < 0.01)
            #expect(abs(a.gainDB - b.gainDB) < 0.01)
        }
    }

    @Test("fit offset ignores blanked regions")
    func fitIgnoresBlanked() {
        let grid = LogGrid.standard
        let target = [Double](repeating: 0, count: grid.count)
        var measured = [Double](repeating: 6, count: grid.count)
        var blanked = [Bool](repeating: false, count: grid.count)
        // A stretch of nonsense that would drag the fit if it were counted.
        for i in 0..<50 { measured[i] = -60; blanked[i] = true }

        let offset = TargetCurve.fitOffset(target: target, measured: measured,
                                           blanked: blanked, range: 0..<grid.count)
        #expect(abs(offset - 6) < 0.01)
    }

    @Test("bundled curves are usable and sorted")
    func bundled() {
        #expect(!TargetCurve.bundled.isEmpty)
        for curve in TargetCurve.bundled {
            #expect(curve.isBuiltIn)
            let sampled = curve.sampled()
            #expect(sampled.count == LogGrid.standard.count)
            let frequencies = curve.points.map(\.frequency)
            #expect(frequencies == frequencies.sorted())
        }
        let flat = TargetCurve.bundled.first { $0.name == "Flat" }!
        #expect(flat.sampled().allSatisfy { abs($0) < 1e-9 })
    }
}

@Suite("Automatic EQ")
struct AutoEQTests {
    let grid = LogGrid.standard

    /// A measurement built by applying known filters to a flat response, so the correction has
    /// something real to find.
    func measurement(_ filters: [Biquad]) -> [Double] {
        filters.combinedResponseDB(on: grid)
    }

    var perfectSNR: [Double] { [Double](repeating: 60, count: grid.count) }

    @Test("flattens a known resonance")
    func correctsAPeak() {
        let room = [Biquad(type: .peaking, frequency: 120, gainDB: 9, q: 3)]
        let measured = measurement(room)
        let target = [Double](repeating: 0, count: grid.count)

        let correction = AutoEQ.correct(measuredDB: measured, targetDB: target,
                                        snrDB: perfectSNR,
                                        settings: EQSettings(maxFrequency: 500))
        #expect(!correction.filters.isEmpty)

        let range = grid.indices(from: 20, to: 500)
        let worstBefore = range.map { abs(measured[$0]) }.max()!
        let worstAfter = range.map { abs(correction.predictedDB[$0]) }.max()!
        #expect(worstAfter < worstBefore * 0.35)
    }

    @Test("handles several resonances at once")
    func correctsMultiplePeaks() {
        let room = [
            Biquad(type: .peaking, frequency: 45, gainDB: 8, q: 4),
            Biquad(type: .peaking, frequency: 110, gainDB: -6, q: 2),
            Biquad(type: .peaking, frequency: 260, gainDB: 5, q: 3)
        ]
        let measured = measurement(room)
        let target = [Double](repeating: 0, count: grid.count)
        let correction = AutoEQ.correct(measuredDB: measured, targetDB: target,
                                        snrDB: perfectSNR,
                                        settings: EQSettings(maxFrequency: 500, maxFilters: 12))

        let range = grid.indices(from: 30, to: 400)
        let errorBefore = range.map { measured[$0] * measured[$0] }.reduce(0, +)
        let errorAfter = range.map { correction.predictedDB[$0] * correction.predictedDB[$0] }
            .reduce(0, +)
        #expect(errorAfter < errorBefore * 0.2)
    }

    @Test("never boosts when told only to cut")
    func onlyCuts() {
        let room = [Biquad(type: .peaking, frequency: 80, gainDB: -10, q: 5)]
        let measured = measurement(room)
        let target = [Double](repeating: 0, count: grid.count)
        let correction = AutoEQ.correct(
            measuredDB: measured, targetDB: target, snrDB: perfectSNR,
            settings: EQSettings(maxFrequency: 500, allowOnlyCuts: true))

        for filter in correction.filters { #expect(filter.gainDB <= 0) }
        #expect(correction.maxBoostDB <= 0.01)
    }

    @Test("refuses to fill in a narrow dip")
    func doesNotBoostNarrowDips() {
        // A deep, narrow null of the kind a standing wave produces. Boosting it flat would
        // fix this one seat and make every other seat worse, so the correction must leave
        // most of it alone.
        let room = [Biquad(type: .peaking, frequency: 90, gainDB: -18, q: 14)]
        let measured = measurement(room)
        let target = [Double](repeating: 0, count: grid.count)
        let settings = EQSettings(maxFrequency: 500)
        let correction = AutoEQ.correct(measuredDB: measured, targetDB: target,
                                        snrDB: perfectSNR, settings: settings)

        // No single boost may ring, and the cascade may not stack past the ceiling either.
        for filter in correction.filters where filter.gainDB > 0 {
            #expect(filter.decayTime60dB <= AutoEQ.maximumBoostDecay)
        }
        #expect(correction.maxBoostDB <= settings.maxTotalBoostDB + 0.01)

        // The null must still be clearly there afterwards — that is the point.
        let at90 = Int(grid.index(of: 90).rounded())
        #expect(correction.predictedDB[at90] < -8)
    }

    @Test("caps the boost of the whole cascade, not just each filter")
    func totalBoostCeiling() {
        // A broad shortfall invites many filters; together they must still respect the ceiling.
        var measured = [Double](repeating: 0, count: grid.count)
        for i in grid.indices(from: 20, to: 400) { measured[i] = -20 }
        let settings = EQSettings(maxFrequency: 500, maxGainDB: 6, maxFilters: 12)
        let correction = AutoEQ.correct(measuredDB: measured,
                                        targetDB: [Double](repeating: 0, count: grid.count),
                                        snrDB: perfectSNR, settings: settings)
        #expect(correction.maxBoostDB <= settings.maxTotalBoostDB + 0.01)
    }

    @Test("respects the maximum filter count and gain")
    func respectsLimits() {
        let room = (1...20).map {
            Biquad(type: .peaking, frequency: Double($0) * 25, gainDB: 7, q: 6)
        }
        let settings = EQSettings(maxFrequency: 500, maxGainDB: 4, maxFilters: 5)
        let correction = AutoEQ.correct(measuredDB: measurement(room),
                                        targetDB: [Double](repeating: 0, count: grid.count),
                                        snrDB: perfectSNR, settings: settings)
        #expect(correction.filters.count <= 5)
        for filter in correction.filters { #expect(abs(filter.gainDB) <= 4.001) }
    }

    @Test("stays inside the requested frequency range")
    func respectsRange() {
        let room = [
            Biquad(type: .peaking, frequency: 60, gainDB: 8, q: 3),
            Biquad(type: .peaking, frequency: 8_000, gainDB: 8, q: 3)
        ]
        let correction = AutoEQ.correct(measuredDB: measurement(room),
                                        targetDB: [Double](repeating: 0, count: grid.count),
                                        snrDB: perfectSNR,
                                        settings: EQSettings(minFrequency: 20, maxFrequency: 300))
        for filter in correction.filters {
            #expect(filter.frequency <= 300 * 1.05)
        }
    }

    @Test("leaves low signal-to-noise regions alone")
    func ignoresBlankedRegions() {
        let room = [Biquad(type: .peaking, frequency: 40, gainDB: 12, q: 3)]
        var snr = [Double](repeating: 60, count: grid.count)
        // Say the measurement could not resolve anything below 80 Hz.
        for i in grid.indices(from: 20, to: 80) { snr[i] = 2 }

        let correction = AutoEQ.correct(measuredDB: measurement(room),
                                        targetDB: [Double](repeating: 0, count: grid.count),
                                        snrDB: snr, settings: EQSettings(maxFrequency: 500))
        for filter in correction.filters { #expect(filter.frequency > 60) }
    }

    @Test("does nothing when the response already matches")
    func noWorkNeeded() {
        let flat = [Double](repeating: 0, count: grid.count)
        let correction = AutoEQ.correct(measuredDB: flat, targetDB: flat, snrDB: perfectSNR,
                                        settings: EQSettings())
        #expect(correction.filters.isEmpty)
        #expect(correction.preampDB == 0)
    }

    @Test("preamp offsets the largest boost")
    func preamp() {
        let room = [Biquad(type: .peaking, frequency: 100, gainDB: -8, q: 2)]
        let correction = AutoEQ.correct(measuredDB: measurement(room),
                                        targetDB: [Double](repeating: 0, count: grid.count),
                                        snrDB: perfectSNR,
                                        settings: EQSettings(maxFrequency: 500))
        #expect(correction.maxBoostDB > 0)
        #expect(abs(correction.preampDB + correction.maxBoostDB) < 1e-9)
    }

    @Test("FIR filter is symmetric and centred")
    func firShape() {
        var correction = [Double](repeating: 0, count: grid.count)
        for i in grid.indices(from: 20, to: 100) { correction[i] = 6 }

        let taps = 4096
        let fir = AutoEQ.firFilter(correctionDB: correction, taps: taps)
        #expect(fir.count == taps)

        // Linear phase means an even filter: the peak sits at the centre and the two halves
        // mirror one another.
        let peak = Deconvolver.peakIndex(of: fir)!
        #expect(abs(peak - taps / 2) <= 1)
        for offset in 1...500 {
            let a = fir[taps / 2 - offset], b = fir[taps / 2 + offset]
            #expect(abs(a - b) < 1e-5)
        }
    }
}
