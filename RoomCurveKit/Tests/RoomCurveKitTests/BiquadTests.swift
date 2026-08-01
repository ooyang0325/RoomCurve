import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Biquad")
struct BiquadTests {
    let sampleRate = 48_000.0

    @Test("peaking filter hits its gain exactly at the centre frequency")
    func peakingGain() {
        for gain in [-12.0, -6.0, 3.0, 9.0] {
            let filter = Biquad(type: .peaking, frequency: 1000, gainDB: gain, q: 2)
            let c = filter.coefficients(sampleRate: sampleRate)
            #expect(abs(c.magnitudeDB(at: 1000, sampleRate: sampleRate) - gain) < 0.01)
        }
    }

    @Test("peaking filter is transparent far from its centre")
    func peakingIsLocal() {
        let filter = Biquad(type: .peaking, frequency: 1000, gainDB: 10, q: 4)
        let c = filter.coefficients(sampleRate: sampleRate)
        #expect(abs(c.magnitudeDB(at: 50, sampleRate: sampleRate)) < 0.2)
        #expect(abs(c.magnitudeDB(at: 18_000, sampleRate: sampleRate)) < 0.5)
    }

    @Test("higher Q makes a narrower peak")
    func qControlsWidth() {
        func width(q: Double) -> Double {
            let c = Biquad(type: .peaking, frequency: 1000, gainDB: 10, q: q)
                .coefficients(sampleRate: sampleRate)
            return abs(c.magnitudeDB(at: 1200, sampleRate: sampleRate))
        }
        #expect(width(q: 1) > width(q: 8))
    }

    @Test("shelf frequency is the midpoint of the transition, not the corner")
    func shelfIsCentreFrequency() {
        // This is the LSC/HSC convention. At the stated frequency the filter must deliver
        // half its gain in dB — that is what distinguishes it from LS/HS.
        let low = Biquad(type: .lowShelf, frequency: 200, gainDB: 12, q: 0.707)
            .coefficients(sampleRate: sampleRate)
        #expect(abs(low.magnitudeDB(at: 200, sampleRate: sampleRate) - 6) < 0.1)
        #expect(abs(low.magnitudeDB(at: 20, sampleRate: sampleRate) - 12) < 0.3)
        #expect(abs(low.magnitudeDB(at: 5_000, sampleRate: sampleRate)) < 0.3)

        let high = Biquad(type: .highShelf, frequency: 4_000, gainDB: -8, q: 0.707)
            .coefficients(sampleRate: sampleRate)
        #expect(abs(high.magnitudeDB(at: 4_000, sampleRate: sampleRate) - (-4)) < 0.1)
        #expect(abs(high.magnitudeDB(at: 20_000, sampleRate: sampleRate) - (-8)) < 0.5)
        #expect(abs(high.magnitudeDB(at: 100, sampleRate: sampleRate)) < 0.3)
    }

    @Test("a boost and an identical cut cancel")
    func boostAndCutCancel() {
        // The RBJ peaking Q is defined so that this is exact.
        let grid = LogGrid.standard
        let filters = [
            Biquad(type: .peaking, frequency: 500, gainDB: 6, q: 3),
            Biquad(type: .peaking, frequency: 500, gainDB: -6, q: 3)
        ]
        for value in filters.combinedResponseDB(on: grid) {
            #expect(abs(value) < 0.01)
        }
    }

    @Test("cascaded filter responses add in dB")
    func cascadeSums() {
        let grid = LogGrid.standard
        let a = Biquad(type: .peaking, frequency: 100, gainDB: 4, q: 1)
        let b = Biquad(type: .peaking, frequency: 5_000, gainDB: -3, q: 2)
        let combined = [a, b].combinedResponseDB(on: grid)
        let separate = zip(a.responseDB(on: grid), b.responseDB(on: grid)).map(+)
        for i in 0..<grid.count {
            #expect(abs(combined[i] - separate[i]) < 1e-9)
        }
    }

    @Test("disabled filters contribute nothing")
    func disabledIsIgnored() {
        let grid = LogGrid.standard
        var filter = Biquad(type: .peaking, frequency: 1000, gainDB: 12, q: 1)
        filter.enabled = false
        for value in [filter].combinedResponseDB(on: grid) {
            #expect(value == 0)
        }
    }

    @Test("Q and octave bandwidth convert both ways")
    func bandwidthConversion() {
        for q in [0.5, 0.707, 1.41, 4.0, 10.0] {
            let filter = Biquad(type: .peaking, frequency: 1000, gainDB: 3, q: q)
            let recovered = Biquad.q(fromBandwidthInOctaves: filter.bandwidthInOctaves)
            #expect(abs(recovered - q) < 1e-6)
        }
    }

    @Test("ringing time rises with Q and falls with frequency")
    func decayTime() {
        let lowQ = Biquad(type: .peaking, frequency: 60, gainDB: 6, q: 1).decayTime60dB
        let highQ = Biquad(type: .peaking, frequency: 60, gainDB: 6, q: 10).decayTime60dB
        #expect(highQ > lowQ)
        // A high-Q boost down low rings long enough to matter — this is the quantity the
        // automatic equaliser uses to refuse such filters.
        #expect(highQ > 0.3)

        let highFreq = Biquad(type: .peaking, frequency: 5_000, gainDB: 6, q: 10).decayTime60dB
        #expect(highFreq < highQ)
    }
}
