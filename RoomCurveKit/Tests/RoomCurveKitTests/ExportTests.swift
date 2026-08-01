import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Export formats")
struct ExportTests {

    var sample: FilterSet {
        FilterSet(title: "Living Room", preampDB: -6.1, filters: [
            Biquad(type: .peaking, frequency: 63, gainDB: -5, q: 4),
            Biquad(type: .lowShelf, frequency: 200, gainDB: 2.5, q: 0.707),
            Biquad(type: .highShelf, frequency: 8_000, gainDB: -2, q: 0.707),
            Biquad(type: .peaking, frequency: 1_000, gainDB: 1, q: 2, enabled: false)
        ], provenance: Provenance(microphone: "iPhone built-in", targetCurve: "Flat"))
    }

    @Test("JSON interchange round trips and states its conventions")
    func jsonRoundTrip() throws {
        let data = try sample.toJSON()
        let text = String(decoding: data, as: UTF8.self)

        // The conventions must be in the file, since these are exactly what differ between
        // tools and corrupt filter sets silently.
        #expect(text.contains("roomcurve.eq/v1"))
        #expect(text.contains("\"shelf_frequency\" : \"centre\""))
        #expect(text.contains("\"preamp_position\""))
        // And coefficients must not be, because they would bake in a sample rate.
        #expect(!text.contains("\"b0\""))

        let restored = try FilterSet.fromJSON(data)
        #expect(restored.title == sample.title)
        #expect(restored.preampDB == sample.preampDB)
        #expect(restored.filters.count == sample.filters.count)
        for (a, b) in zip(restored.filters, sample.filters) {
            #expect(a.type == b.type)
            #expect(a.frequency == b.frequency)
            #expect(a.gainDB == b.gainDB)
            #expect(a.q == b.q)
            #expect(a.enabled == b.enabled)
        }
    }

    @Test("ParametricEQ text matches the AutoEQ dialect")
    func parametricEQText() {
        let text = sample.toParametricEQText()
        #expect(text.contains("Preamp: -6.1 dB"))
        #expect(text.contains("Filter 1: ON PK Fc 63 Hz Gain -5.0 dB Q 4.00"))
        // Shelves must be emitted as centre-frequency LSC/HSC, matching the internal convention.
        #expect(text.contains("LSC"))
        #expect(text.contains("HSC"))
        // The disabled filter is not exported.
        #expect(!text.contains("Filter 4"))
    }

    @Test("ParametricEQ text round trips through the parser")
    func parametricEQRoundTrip() {
        let restored = FilterSet.fromParametricEQText(sample.toParametricEQText())
        #expect(abs(restored.preampDB - (-6.1)) < 0.05)
        #expect(restored.filters.count == 3)
        #expect(restored.filters[0].type == .peaking)
        #expect(abs(restored.filters[0].frequency - 63) < 0.1)
        #expect(restored.filters[1].type == .lowShelf)
        #expect(restored.filters[2].type == .highShelf)
    }

    @Test("parser tolerates real REW output with padding and disabled filters")
    func parsesREWOutput() {
        let rew = """
        Equaliser: Generic
        Room EQ V5.31.2
        Dated: 24 Jan 2025 15:32:38

        Notes:

        Filter  1: ON  PK       Fc    63.0 Hz  Gain  -5.00 dB  Q  4.000
        Filter  2: ON  LSC      Fc   200.0 Hz  Gain   2.50 dB  Q  0.707
        Filter  3: OFF PK       Fc  1000.0 Hz  Gain   0.00 dB  Q  1.000
        """
        let set = FilterSet.fromParametricEQText(rew)
        #expect(set.filters.count == 3)
        #expect(set.filters[0].enabled)
        #expect(set.filters[1].type == .lowShelf)
        #expect(!set.filters[2].enabled)
    }

    @Test("biquad export negates the feedback coefficients")
    func biquadSignConvention() {
        let text = sample.toBiquadCoefficients(sampleRate: 48_000)
        #expect(text.contains("biquad1,"))
        #expect(text.contains("48000 Hz"))
        #expect(text.lowercased().contains("negated"))

        let filter = sample.active[0]
        let c = filter.coefficients(sampleRate: 48_000)
        // The file must carry the opposite sign to the internal representation.
        let line = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("a1=") }!
        let exported = Double(line.dropFirst(3).dropLast())!
        #expect(abs(exported - (-c.a1)) < 1e-6)
    }

    @Test("coefficients differ by sample rate, which is why they are never stored")
    func coefficientsAreRateDependent() {
        let at48 = sample.toBiquadCoefficients(sampleRate: 48_000)
        let at96 = sample.toBiquadCoefficients(sampleRate: 96_000)
        #expect(at48 != at96)
    }

    @Test("CamillaDSP YAML has filters and a pipeline per channel")
    func camillaDSP() {
        let yaml = sample.toCamillaDSPYAML(channels: 2)
        #expect(yaml.contains("type: Biquad"))
        #expect(yaml.contains("type: Peaking"))
        #expect(yaml.contains("type: Lowshelf"))
        #expect(yaml.contains("type: Highshelf"))
        #expect(yaml.contains("channel: 0"))
        #expect(yaml.contains("channel: 1"))
        #expect(yaml.contains("gain: -6.10"))
    }

    @Test("mpv chain uses the right filter per shape")
    func mpvChain() {
        let chain = sample.toMPVFilterChain()
        #expect(chain.hasPrefix("af="))
        #expect(chain.contains("volume=-6.10dB"))
        // FFmpeg's equalizer is peaking-only; shelves need their own filters.
        #expect(chain.contains("equalizer=f=63"))
        #expect(chain.contains("lowshelf=f=200"))
        #expect(chain.contains("highshelf=f=8000"))
        #expect(sample.toMPVConf().contains("mpv.conf"))
    }

    @Test("manual card for a parametric target lists every filter")
    func parametricCard() {
        let card = sample.toManualCard(.parametricManual)
        #expect(card.contains("Living Room"))
        #expect(card.contains("63"))
        #expect(card.contains("200"))
        #expect(card.contains("8000"))
    }

    @Test("manual card for Sony projects onto its fixed bands")
    func sonyCard() {
        let card = sample.toManualCard(.sonyWalkman)
        for frequency in ManualEQTarget.sonyWalkman.bandFrequencies {
            #expect(card.contains(String(format: "%6.0f Hz", frequency)))
        }
        #expect(card.contains("No import"))
        // Values must be whole numbers within ±10 dB, which is all the hardware accepts.
        for line in card.split(whereSeparator: \.isNewline) where line.contains(" Hz ") {
            let fields = line.split(separator: " ").map(String.init)
            if let value = Double(fields.first(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) ?? "") {
                #expect(abs(value) <= 10)
                #expect(value == value.rounded())
            }
        }
    }

    @Test("Sony and Walkman targets use different band centres")
    func sonyTargetsDiffer() {
        #expect(ManualEQTarget.sonyWalkman.bandFrequencies
                != ManualEQTarget.sonyHeadphones.bandFrequencies)
    }
}

@Suite("WAV files")
struct WAVTests {

    @Test("float WAV round trips")
    func roundTrip() throws {
        let samples = (0..<1000).map { Float(sin(Double($0) * 0.05)) }
        let audio = WAVFile.Audio(samples: samples, sampleRate: 48_000)
        let decoded = try WAVFile.decode(WAVFile.encode(audio))
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.channels == 1)
        #expect(decoded.samples.count == samples.count)
        for (a, b) in zip(decoded.samples, samples) { #expect(a == b) }
    }

    @Test("rejects a file that is not a WAV")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try WAVFile.decode(Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]))
        }
    }

    @Test("impulse response survives a WAV round trip")
    func impulseResponseRoundTrip() throws {
        var samples = [Float](repeating: 0, count: 48_000)
        samples[12_000] = 1.0
        let ir = ImpulseResponse(samples: samples, sampleRate: 48_000, acousticDelay: 0,
                                 noiseFloor: [], clockDriftPPM: nil)
        let restored = try ImpulseResponse.fromWAV(ir.wavData())
        #expect(restored.sampleRate == 48_000)
        #expect(Deconvolver.peakIndex(of: restored.samples) == 12_000)
        #expect(restored.peakIndex == 12_000) // the 250 ms convention
    }

    @Test("filter set renders to a convolution impulse response")
    func filterSetToIR() throws {
        let set = FilterSet(preampDB: -3, filters: [
            Biquad(type: .peaking, frequency: 100, gainDB: -6, q: 2)
        ])
        let audio = try WAVFile.decode(set.impulseResponseWAV(taps: 4096))
        #expect(audio.samples.count == 4096)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.samples.contains { $0 != 0 })
    }
}
