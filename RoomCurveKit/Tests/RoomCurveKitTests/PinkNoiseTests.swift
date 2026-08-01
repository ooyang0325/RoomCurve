import Testing
import Foundation
@testable import RoomCurveKit

@Suite("Pink noise and RTA")
struct PinkNoiseTests {

    @Test("generated noise is bounded and reproducible")
    func generation() {
        let a = PinkNoiseGenerator.make(duration: 1)
        let b = PinkNoiseGenerator.make(duration: 1)
        #expect(a.samples.count == 48_000)
        #expect(a.samples.allSatisfy { abs($0) <= 1.0 })
        #expect(a.samples == b.samples) // same seed, same file
    }

    @Test("noise has a pink slope: about 3 dB less power per octave")
    func pinkSlope() {
        let noise = PinkNoiseGenerator.make(duration: 4)
        let grid = LogGrid.standard
        func powerDB(at frequency: Double) -> Double {
            let i = Int(grid.index(of: frequency).rounded())
            return 10 * log10(noise.referencePower[i])
        }
        // Per octave the power should fall by roughly 3 dB.
        let drop = powerDB(at: 250) - powerDB(at: 4_000)
        #expect(abs(drop - 12) < 4) // four octaves × ~3 dB
    }

    @Test("a flat system reads flat")
    func flatSystemReadsFlat() {
        let noise = PinkNoiseGenerator.make(duration: 4)
        let analyser = RealTimeAnalyser(stimulus: noise, mode: .average)
        // Play the noise straight back in: the system under test is a wire.
        analyser.process(noise.samples)

        let response = analyser.response()!
        let grid = response.grid
        let range = grid.indices(from: 50, to: 15_000)
        let values = range.map { response.magnitudeDB[$0] }
        let mean = values.reduce(0, +) / Double(values.count)
        for value in values {
            #expect(abs(value - mean) < 2.0)
        }
    }

    @Test("a filtered system shows the filter")
    func filteredSystemShowsFilter() {
        let noise = PinkNoiseGenerator.make(duration: 4)
        let analyser = RealTimeAnalyser(stimulus: noise, mode: .average)

        // Push the noise through a known resonance before measuring it.
        let filter = Biquad(type: .peaking, frequency: 1_000, gainDB: 12, q: 1.5)
        let c = filter.coefficients(sampleRate: 48_000)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var filtered = [Float](repeating: 0, count: noise.samples.count)
        for (i, sample) in noise.samples.enumerated() {
            let x = Double(sample)
            let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            filtered[i] = Float(y)
        }
        analyser.process(filtered)

        let response = analyser.response()!.smoothed(.oct1_6)
        let grid = response.grid
        let at1k = response.magnitudeDB[Int(grid.index(of: 1_000).rounded())]
        let at100 = response.magnitudeDB[Int(grid.index(of: 100).rounded())]
        #expect(at1k - at100 > 8)
    }

    @Test("handles arbitrary buffer sizes")
    func arbitraryBufferSizes() {
        let noise = PinkNoiseGenerator.make(duration: 2)
        let analyser = RealTimeAnalyser(stimulus: noise, mode: .average)
        var offset = 0
        var size = 137
        while offset < noise.samples.count {
            let end = Swift.min(offset + size, noise.samples.count)
            analyser.process(Array(noise.samples[offset..<end]))
            offset = end
            size = size * 3 % 2000 + 64
        }
        #expect(analyser.hasData)
        #expect(analyser.response() != nil)
    }

    @Test("reset clears accumulated data")
    func reset() {
        let noise = PinkNoiseGenerator.make(duration: 1)
        let analyser = RealTimeAnalyser(stimulus: noise, mode: .average)
        analyser.process(noise.samples)
        #expect(analyser.hasData)
        analyser.reset()
        #expect(!analyser.hasData)
        #expect(analyser.response() == nil)
    }
}

@Suite("Microphone calibration")
struct CalibrationTests {

    /// A response that is flat except for a defined shape.
    func response(shape: (Double) -> Double, grid: LogGrid = .standard) -> FrequencyResponse {
        FrequencyResponse(
            grid: grid,
            magnitudeDB: grid.frequencies.map(shape),
            phaseDegrees: [Double](repeating: 0, count: grid.count),
            groupDelayMS: [Double](repeating: 0, count: grid.count),
            snrDB: [Double](repeating: 60, count: grid.count))
    }

    @Test("calibration files use the subtract convention")
    func subtractConvention() {
        let grid = LogGrid.standard
        let measured = response(shape: { _ in 0 })
        // A microphone that reads 8 dB low must raise the measurement by 8 dB.
        let calibration = [Double](repeating: -8, count: grid.count)
        let corrected = measured.applying(calibrationDB: calibration)
        #expect(abs(corrected.magnitudeDB[100] - 8) < 1e-9)
    }

    @Test("derives a microphone's deviation by comparison with a reference")
    func derive() {
        let grid = LogGrid.standard
        // The reference sees the speaker as it is; the microphone under test rolls off low.
        let reference = response(shape: { _ in 0 })
        let underTest = response(shape: { f in f < 100 ? -10 * (1 - log2(f / 20) / log2(5)) : 0 })

        let calibration = MicrophoneCalibration.derive(
            reference: reference, microphone: underTest, name: "Test phone")
        let sampled = calibration.sampled(on: grid)

        // Flat where both agree, and about −10 dB where the microphone under-reads.
        #expect(abs(sampled[Int(grid.index(of: 1_000).rounded())]) < 0.5)
        #expect(abs(sampled[Int(grid.index(of: 20).rounded())] - (-10)) < 1.5)
        #expect(!calibration.isEstimate)
    }

    @Test("derived calibration undoes the error it describes")
    func derivedCalibrationCorrects() {
        let grid = LogGrid.standard
        let reference = response(shape: { _ in 0 })
        // A smooth low-frequency rolloff, as a real capsule has. Deriving a calibration applies
        // fractional-octave smoothing, so a step discontinuity would be rounded off by design;
        // testing against one would only measure the smoothing.
        let rolloff = { (f: Double) in -6 / (1 + pow(f / 150, 2)) }
        let underTest = response(shape: rolloff)

        let calibration = MicrophoneCalibration.derive(
            reference: reference, microphone: underTest, name: "Test")
        let corrected = underTest.applying(calibrationDB: calibration.sampled(on: grid))

        // Applying it to the microphone that produced it should bring it back to the reference.
        for i in grid.indices(from: 30, to: 15_000) {
            #expect(abs(corrected.magnitudeDB[i] - reference.magnitudeDB[i]) < 0.5)
        }
    }

    @Test("built-in estimate is labelled as an estimate everywhere")
    func estimateIsLabelled() {
        let estimate = MicrophoneCalibration.builtInEstimate
        #expect(estimate.isEstimate)
        #expect(estimate.name.lowercased().contains("estimate"))
        #expect(estimate.serialised().contains("ESTIMATE"))

        // Shaped as documented: flat midrange, rolling off at both extremes.
        let grid = LogGrid.standard
        let sampled = estimate.sampled(on: grid)
        #expect(abs(sampled[Int(grid.index(of: 1_000).rounded())]) < 0.1)
        #expect(sampled[Int(grid.index(of: 20).rounded())] < -8)
        #expect(sampled[Int(grid.index(of: 20_000).rounded())] < -3)
    }

    @Test("calibration files round trip as text")
    func textRoundTrip() throws {
        let original = MicrophoneCalibration.builtInEstimate
        let restored = try #require(MicrophoneCalibration.parse(original.serialised(),
                                                               name: original.name))
        #expect(restored.points.count == original.points.count)
        for (a, b) in zip(original.points, restored.points) {
            #expect(abs(a.frequency - b.frequency) < 0.01)
            #expect(abs(a.gainDB - b.gainDB) < 0.01)
        }
    }

    @Test("none means no change")
    func noneIsNeutral() {
        #expect(MicrophoneCalibration.none.sampled().allSatisfy { abs($0) < 1e-9 })
    }
}

@Suite("Measured calibrations")
struct MeasuredCalibrationTests {
    let grid = LogGrid.standard

    @Test("iPhone 17 Pro curve is measured, attributed, and shaped as published")
    func iPhone17Pro() {
        let calibration = MicrophoneCalibration.iPhone17Pro
        #expect(!calibration.isEstimate)
        #expect(calibration.source?.contains("Faber") == true)
        #expect(calibration.notes?.isEmpty == false)

        let sampled = calibration.sampled(on: grid)
        func value(at frequency: Double) -> Double {
            sampled[Int(grid.index(of: frequency).rounded())]
        }

        // Flat through the midrange, which is where room correction operates.
        for frequency in [315.0, 500, 1_000, 2_000] {
            #expect(abs(value(at: frequency)) < 1.0)
        }
        // A deeper low-frequency rolloff than the usual "below 60 Hz" folklore implies.
        #expect(abs(value(at: 50) - (-3.5)) < 0.5)
        #expect(abs(value(at: 31.5) - (-7.0)) < 0.5)
        #expect(value(at: 20) < -14)
        // The high-frequency port resonance is present.
        #expect(value(at: 11_200) > 8)
    }

    @Test("applying the iPhone 17 Pro curve lifts the bass back up")
    func correctsBass() {
        let calibration = MicrophoneCalibration.iPhone17Pro.sampled(on: grid)
        let flat = FrequencyResponse(
            grid: grid,
            magnitudeDB: [Double](repeating: 0, count: grid.count),
            phaseDegrees: [Double](repeating: 0, count: grid.count),
            groupDelayMS: [Double](repeating: 0, count: grid.count),
            snrDB: [Double](repeating: 60, count: grid.count))
        let corrected = flat.applying(calibrationDB: calibration)
        // A microphone reading 7 dB low at 31.5 Hz means the real level was 7 dB higher.
        #expect(abs(corrected.magnitudeDB[Int(grid.index(of: 31.5).rounded())] - 7.0) < 0.5)
    }

    @Test("bundled list marks estimates apart from measurements")
    func bundledList() {
        let bundled = MicrophoneCalibration.bundled
        #expect(bundled.contains { $0.isEstimate })
        #expect(bundled.contains { !$0.isEstimate && $0.source != nil })
    }

    @Test("source and notes survive serialisation")
    func serialisationCarriesProvenance() {
        let text = MicrophoneCalibration.iPhone17Pro.serialised()
        #expect(text.contains("Faber"))
        #expect(text.contains("USB-C"))
    }
}
