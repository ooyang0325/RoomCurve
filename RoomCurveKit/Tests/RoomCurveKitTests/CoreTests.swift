import Testing
import Foundation
@testable import RoomCurveKit

@Suite("FFT")
struct FFTTests {

    @Test("round trips a signal back to itself")
    func roundTrip() {
        let fft = FFTProcessor(length: 1024)
        let signal = (0..<1024).map { Float(sin(Double($0) * 0.1) + 0.3 * cos(Double($0) * 0.7)) }
        let recovered = fft.inverse(fft.forward(signal))
        for i in 0..<1024 {
            #expect(abs(recovered[i] - signal[i]) < 1e-4)
        }
    }

    @Test("puts a pure tone in the expected bin")
    func toneLandsInBin() {
        let n = 1024
        let fft = FFTProcessor(length: n)
        let bin = 64
        let signal = (0..<n).map { Float(cos(2 * Double.pi * Double(bin) * Double($0) / Double(n))) }
        let mag = fft.forward(signal).magnitude
        let peak = mag[0..<(n / 2)].enumerated().max { $0.element < $1.element }!.offset
        #expect(peak == bin)
    }

    @Test("complex multiply convolves in the time domain")
    func multiplyIsConvolution() {
        // Convolving with a unit impulse delayed by d must delay the signal by d.
        let n = 256
        let fft = FFTProcessor(length: n)
        var signal = [Float](repeating: 0, count: n)
        for i in 0..<8 { signal[i] = Float(i + 1) }
        var impulse = [Float](repeating: 0, count: n)
        let delay = 20
        impulse[delay] = 1

        let result = fft.inverse(fft.forward(signal).multiplied(by: fft.forward(impulse)))
        for i in 0..<8 {
            #expect(abs(result[i + delay] - signal[i]) < 1e-3)
        }
    }

    @Test("rounds lengths up to a power of two")
    func powerOfTwoRounding() {
        #expect(FFTProcessor.length(atLeast: 1000) == 1024)
        #expect(FFTProcessor.length(atLeast: 1024) == 1024)
        #expect(FFTProcessor.length(atLeast: 1025) == 2048)
    }
}

@Suite("LogGrid")
struct LogGridTests {

    @Test("spans the requested range with uniform log spacing")
    func spacing() {
        let grid = LogGrid.standard
        #expect(abs(grid.frequencies.first! - 20) < 1e-9)
        #expect(abs(grid.frequencies.last! - 20_000) < 1e-6)
        // Every step is the same ratio.
        let ratio = grid.frequencies[1] / grid.frequencies[0]
        for i in 1..<grid.count {
            #expect(abs(grid.frequencies[i] / grid.frequencies[i - 1] - ratio) < 1e-9)
        }
        // One octave up must be pointsPerOctave steps along.
        let i1k = grid.index(of: 1000), i2k = grid.index(of: 2000)
        #expect(abs((i2k - i1k) - grid.pointsPerOctave) < 1e-9)
    }

    @Test("interpolates a curve in log frequency and holds ends flat")
    func interpolation() {
        let grid = LogGrid.standard
        let curve = grid.interpolate(points: [(100, 0), (1000, -10)])
        // Held flat below the first point and above the last.
        #expect(abs(curve[0] - 0) < 1e-9)
        #expect(abs(curve[grid.count - 1] - (-10)) < 1e-9)
        // Geometric midpoint of 100 and 1000 must be the arithmetic midpoint of 0 and -10.
        let mid = Int(grid.index(of: sqrt(100 * 1000)).rounded())
        #expect(abs(curve[mid] - (-5)) < 0.05)
    }

    @Test("smoothing preserves a flat curve and tames a narrow notch")
    func smoothing() {
        let grid = LogGrid.standard
        let flat = [Double](repeating: 1.0, count: grid.count)
        for v in grid.smoothed(linearMagnitude: flat, .oct1_3) {
            #expect(abs(v - 1.0) < 1e-9)
        }

        var notched = flat
        let centre = Int(grid.index(of: 1000).rounded())
        notched[centre] = 0.1
        let smoothed = grid.smoothed(linearMagnitude: notched, .oct1_3)
        // The notch is filled in substantially but not erased.
        #expect(smoothed[centre] > 0.5)
        #expect(smoothed[centre] < 1.0)
    }

    @Test("wider smoothing settings smooth more")
    func smoothingIsMonotonic() {
        let grid = LogGrid.standard
        var notched = [Double](repeating: 1.0, count: grid.count)
        let centre = Int(grid.index(of: 1000).rounded())
        notched[centre] = 0.1
        let narrow = grid.smoothed(linearMagnitude: notched, .oct1_24)[centre]
        let wide = grid.smoothed(linearMagnitude: notched, .oct1_3)[centre]
        #expect(wide > narrow)
    }

    @Test("band-averages when a cell spans many FFT bins")
    func resampleAverages() {
        let grid = LogGrid.standard
        // Alternating bins: a point sample would return 0 or 2 depending on parity,
        // an average must return ~1.
        let bins = (0..<48_000).map { Double($0 % 2 == 0 ? 0 : 2) }
        let resampled = grid.resample(bins: bins, binSpacing: 1.0)
        let at10k = Int(grid.index(of: 10_000).rounded())
        #expect(abs(resampled[at10k] - 1.0) < 0.05)
    }
}
