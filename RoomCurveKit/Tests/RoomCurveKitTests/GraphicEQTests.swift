import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Graphic EQ fitting")
struct GraphicEQTests {
    let grid = LogGrid.standard

    /// A correction to aim at, built from parametric filters.
    func target(_ filters: [Biquad]) -> [Double] {
        filters.combinedResponseDB(on: grid)
    }

    @Test("more bands fit better than fewer")
    func moreBandsFitBetter() {
        let wanted = target([
            Biquad(type: .peaking, frequency: 120, gainDB: -6, q: 2),
            Biquad(type: .peaking, frequency: 900, gainDB: 4, q: 1.5),
            Biquad(type: .peaking, frequency: 5_000, gainDB: -3, q: 2)
        ])
        let five = GraphicEQFitter.fit(targetDB: wanted, to: .fiveBand)
        let ten = GraphicEQFitter.fit(targetDB: wanted, to: .tenBand)
        let thirtyOne = GraphicEQFitter.fit(targetDB: wanted, to: .thirtyOneBand)

        #expect(ten.rmsErrorDB < five.rmsErrorDB)
        #expect(thirtyOne.rmsErrorDB < ten.rmsErrorDB)
        // A third-octave equaliser should track a gentle correction closely.
        #expect(thirtyOne.rmsErrorDB < 1.0)
    }

    @Test("beats reading the target off at each band centre")
    func beatsPointSampling() {
        // Bands overlap, so taking the value at each centre over-corrects in between. This is
        // the whole reason the bands have to be solved together.
        let wanted = target([Biquad(type: .peaking, frequency: 500, gainDB: 8, q: 1.2)])
        let eq = GraphicEQ.tenBand

        let naive = eq.frequencies.map { frequency -> Double in
            let i = Int(grid.index(of: frequency).rounded()).clamped(to: 0...(grid.count - 1))
            return GraphicEQFitter.quantise(wanted[i], to: eq)
        }
        let naiveResponse = eq.filters(gains: naive).combinedResponseDB(on: grid)

        let fitted = GraphicEQFitter.fit(targetDB: wanted, to: eq)
        let range = grid.indices(from: 60, to: 16_000)

        func rms(_ response: [Double]) -> Double {
            let errors = range.map { response[$0] - wanted[$0] }
            return (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot()
        }
        #expect(fitted.rmsErrorDB < rms(naiveResponse))
    }

    @Test("respects the gain range and step")
    func respectsLimits() {
        let wanted = target([Biquad(type: .peaking, frequency: 1_000, gainDB: 20, q: 1)])
        let eq = GraphicEQ(name: "Tight", frequencies: [250, 500, 1_000, 2_000, 4_000],
                           minGainDB: -6, maxGainDB: 6, stepDB: 2)
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: eq)

        for gain in fit.gains {
            #expect(gain >= -6.001 && gain <= 6.001)
            // Every value must land on a step the device actually offers.
            #expect(abs((gain / 2).rounded() * 2 - gain) < 1e-9)
        }
        #expect(fit.clipped)
    }

    @Test("a finer step fits more closely")
    func finerStepFitsBetter() {
        let wanted = target([
            Biquad(type: .peaking, frequency: 160, gainDB: -5, q: 2),
            Biquad(type: .peaking, frequency: 2_000, gainDB: 3.5, q: 1.5)
        ])
        func error(step: Double) -> Double {
            var eq = GraphicEQ.tenBand
            eq.stepDB = step
            return GraphicEQFitter.fit(targetDB: wanted, to: eq).rmsErrorDB
        }
        // Coarse steps quantise away detail the bands could otherwise reach.
        #expect(error(step: 0.1) <= error(step: 1.0) + 1e-9)
        #expect(error(step: 1.0) <= error(step: 3.0) + 1e-9)
    }

    @Test("lands on tenth-of-a-dB steps when asked")
    func tenthOfADecibelStep() {
        let wanted = target([Biquad(type: .peaking, frequency: 400, gainDB: 4.35, q: 1.5)])
        var eq = GraphicEQ.tenBand
        eq.stepDB = 0.1
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: eq)

        for gain in fit.gains {
            #expect(abs((gain * 10).rounded() / 10 - gain) < 1e-9)
        }
        // A tenth of a dB is fine enough to be limited by the bands, not the step.
        #expect(fit.rmsErrorDB < 1.0)
    }

    @Test("handles any band count, from three to fifty")
    func arbitraryBandCounts() {
        let wanted = target([Biquad(type: .peaking, frequency: 200, gainDB: -5, q: 1.5)])
        for count in [3, 5, 8, 12, 31, 50] {
            let frequencies = (0..<count).map { 20 * pow(1_000, Double($0) / Double(count - 1)) }
            let eq = GraphicEQ(name: "\(count)-band", frequencies: frequencies)
            let fit = GraphicEQFitter.fit(targetDB: wanted, to: eq)
            #expect(fit.gains.count == count)
            #expect(fit.gains.allSatisfy { $0.isFinite })
        }
    }

    @Test("leaves a flat target alone")
    func flatTargetIsNoChange() {
        let flat = [Double](repeating: 0, count: grid.count)
        let fit = GraphicEQFitter.fit(targetDB: flat, to: .tenBand)
        for gain in fit.gains { #expect(abs(gain) < 1.01) }
        #expect(fit.rmsErrorDB < 0.5)
    }

    @Test("does not answer with huge opposing gains that cancel")
    func noWildAlternatingGains() {
        // Closely spaced bands are nearly interchangeable; without regularisation a solver
        // will happily return +30/-30 pairs that cancel out.
        let wanted = target([Biquad(type: .peaking, frequency: 1_000, gainDB: 3, q: 1)])
        let frequencies = (0..<24).map { 200 * pow(2, Double($0) / 8) }
        let eq = GraphicEQ(name: "Dense", frequencies: frequencies,
                           minGainDB: -40, maxGainDB: 40, stepDB: 0.5)
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: eq)
        for gain in fit.gains { #expect(abs(gain) < 12) }
    }

    @Test("band Q follows band spacing")
    func qFromSpacing() {
        // Octave spacing lands near 1.4, third-octave near 4.3 — what real hardware uses.
        let octave = GraphicEQ.tenBand
        #expect(abs(octave.q(forBandAt: 5) - 1.41) < 0.3)

        let third = GraphicEQ.thirtyOneBand
        #expect(abs(third.q(forBandAt: 15) - 4.3) < 0.8)

        // An explicit Q overrides the derivation.
        let fixed = GraphicEQ(name: "Fixed", frequencies: [100, 1_000], q: 2.5)
        #expect(fixed.q(forBandAt: 0) == 2.5)
    }

    @Test("reports how close it got")
    func reportsError() {
        let wanted = target([Biquad(type: .peaking, frequency: 800, gainDB: -6, q: 3)])
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: .fiveBand)
        #expect(fit.maxErrorDB >= fit.rmsErrorDB)
        #expect(fit.achievedDB.count == grid.count)

        // The reported response must be the real cascade, not the linear approximation.
        let actual = fit.filters.combinedResponseDB(on: grid)
        for i in 0..<grid.count { #expect(abs(actual[i] - fit.achievedDB[i]) < 1e-9) }
    }

    @Test("card lists every band and says how close it gets")
    func card() {
        let wanted = target([Biquad(type: .peaking, frequency: 100, gainDB: 5, q: 2)])
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: .sonyWalkman)
        let card = fit.card(title: "Living Room")
        #expect(card.contains("Living Room"))
        #expect(card.contains("Sony Walkman"))
        for frequency in GraphicEQ.sonyWalkman.frequencies {
            let label = frequency >= 1_000
                ? String(format: "%.4g kHz", frequency / 1_000)
                : String(format: "%.4g Hz", frequency)
            #expect(card.contains(label))
        }
        #expect(card.lowercased().contains("error"))
    }

    @Test("emits the GraphicEQ line other apps read")
    func graphicEQLine() {
        let wanted = target([Biquad(type: .peaking, frequency: 100, gainDB: 5, q: 2)])
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: .tenBand)
        let line = fit.graphicEQLine()
        #expect(line.hasPrefix("GraphicEQ: "))
        #expect(line.components(separatedBy: ";").count == 10)
    }

    @Test("copes with a single band")
    func singleBand() {
        let wanted = target([Biquad(type: .peaking, frequency: 1_000, gainDB: 4, q: 1)])
        let eq = GraphicEQ(name: "One", frequencies: [1_000])
        let fit = GraphicEQFitter.fit(targetDB: wanted, to: eq)
        #expect(fit.gains.count == 1)
        #expect(fit.gains[0] > 1)
    }
}
