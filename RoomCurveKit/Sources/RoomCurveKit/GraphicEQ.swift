import Foundation

/// A fixed-band graphic equaliser, described by what it can actually do.
///
/// Anything from a five-band on a portable player to a 31-band rack unit. The three things that
/// matter are which frequencies it offers, how finely it can be set, and how far it will go.
public struct GraphicEQ: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var frequencies: [Double]
    public var minGainDB: Double
    public var maxGainDB: Double
    /// Smallest adjustment the device accepts — 1 dB on most hardware, 0.5 on some.
    public var stepDB: Double
    /// Q of each band. Left empty, it is derived from how far apart the bands sit, which is
    /// what a real graphic equaliser does.
    public var q: Double?

    public init(name: String, frequencies: [Double], minGainDB: Double = -12,
                maxGainDB: Double = 12, stepDB: Double = 1, q: Double? = nil) {
        self.name = name
        self.frequencies = frequencies.sorted()
        self.minGainDB = minGainDB
        self.maxGainDB = maxGainDB
        self.stepDB = stepDB
        self.q = q
    }

    public var gainRange: ClosedRange<Double> { minGainDB...maxGainDB }

    /// Every setting a band can be put to.
    public var levels: [Double] {
        guard stepDB > 0 else { return [0] }
        let count = Int(((maxGainDB - minGainDB) / stepDB).rounded()) + 1
        return (0..<count).map { (minGainDB + Double($0) * stepDB).clamped(to: gainRange) }
    }

    /// Q for one band, from the spacing to its neighbours.
    ///
    /// A graphic equaliser's bands are as wide as they are far apart — that is what makes the
    /// set of them cover the spectrum without gaps or heavy overlap. An octave-spaced band
    /// works out near Q 1.4, a third-octave one near Q 4.3, which is what real hardware uses.
    public func q(forBandAt index: Int) -> Double {
        if let q { return q }
        guard frequencies.count > 1 else { return 1.41 }

        let octaves: Double
        switch index {
        case 0:
            octaves = log2(frequencies[1] / frequencies[0])
        case frequencies.count - 1:
            octaves = log2(frequencies[index] / frequencies[index - 1])
        default:
            octaves = log2(frequencies[index + 1] / frequencies[index - 1]) / 2
        }
        return Biquad.q(fromBandwidthInOctaves: Swift.max(octaves, 0.05))
    }

    public func filters(gains: [Double]) -> [Biquad] {
        zip(frequencies.indices, gains).compactMap { index, gain in
            guard abs(gain) > 1e-9 else { return nil }
            return Biquad(type: .peaking, frequency: frequencies[index],
                          gainDB: gain, q: q(forBandAt: index))
        }
    }
}

/// The result of matching a graphic equaliser to a correction.
public struct GraphicEQFit: Sendable {
    public let eq: GraphicEQ
    /// One value per band, already clamped and rounded to what the device accepts.
    public let gains: [Double]
    /// What the equaliser will actually do, on the shared grid.
    public let achievedDB: [Double]
    /// What was being aimed at.
    public let targetDB: [Double]
    public let maxErrorDB: Double
    public let rmsErrorDB: Double
    /// True when a band ran out of travel, so the fit is limited by the hardware.
    public let clipped: Bool

    public var filters: [Biquad] { eq.filters(gains: gains) }
}

public enum GraphicEQFitter {

    /// Find the band settings that come closest to a desired correction.
    ///
    /// Reading the correction off at each band's centre frequency — the obvious approach — is
    /// wrong, because graphic equaliser bands overlap. Neighbouring bands both contribute at
    /// the frequencies between them, so setting each to the value it "should" have there
    /// over-corrects everywhere in between. The bands have to be solved together.
    ///
    /// Least squares gives the starting point, then the gains are rounded onto the steps the
    /// device actually offers and refined by trying each band's neighbouring settings against
    /// the real filter responses. Rounding first and stopping there would be worse than it
    /// needs to be: rounding one band up is often best answered by nudging its neighbour down,
    /// which only a search over the true responses will find.
    public static func fit(targetDB: [Double],
                           to eq: GraphicEQ,
                           grid: LogGrid = .standard,
                           sampleRate: Double = 48_000) -> GraphicEQFit {
        let bands = eq.frequencies.count
        guard bands > 0, let first = eq.frequencies.first,
              let last = eq.frequencies.last else {
            return GraphicEQFit(eq: eq, gains: [], achievedDB: targetDB, targetDB: targetDB,
                                maxErrorDB: 0, rmsErrorDB: 0, clipped: false)
        }

        // Judge the fit across the span the equaliser can actually reach, with half an octave
        // of margin. Scoring it outside that range would only measure the bands it does not have.
        let fitRange = grid.indices(from: first / 1.5, to: last * 1.5)
        guard !fitRange.isEmpty else {
            return GraphicEQFit(eq: eq, gains: [Double](repeating: 0, count: bands),
                                achievedDB: [Double](repeating: 0, count: grid.count),
                                targetDB: targetDB, maxErrorDB: 0, rmsErrorDB: 0,
                                clipped: false)
        }

        // Unit-gain shape of each band, used to set up the linear solve.
        let unit = (0..<bands).map { index in
            Biquad(type: .peaking, frequency: eq.frequencies[index], gainDB: 1,
                   q: eq.q(forBandAt: index)).responseDB(on: grid, sampleRate: sampleRate)
        }

        var gains = leastSquares(unit: unit, target: targetDB, over: fitRange, bands: bands)
        gains = gains.map { quantise($0, to: eq) }
        gains = refine(gains, eq: eq, target: targetDB, over: fitRange,
                       grid: grid, sampleRate: sampleRate)

        let achieved = eq.filters(gains: gains).combinedResponseDB(on: grid,
                                                                  sampleRate: sampleRate)
        var maxError = 0.0
        var sumSquares = 0.0
        for i in fitRange {
            let error = achieved[i] - targetDB[i]
            maxError = Swift.max(maxError, abs(error))
            sumSquares += error * error
        }

        let clipped = gains.contains {
            abs($0 - eq.minGainDB) < 1e-9 || abs($0 - eq.maxGainDB) < 1e-9
        }

        return GraphicEQFit(eq: eq, gains: gains, achievedDB: achieved, targetDB: targetDB,
                            maxErrorDB: maxError,
                            rmsErrorDB: (sumSquares / Double(fitRange.count)).squareRoot(),
                            clipped: clipped)
    }

    // MARK: - Steps

    /// Solve the normal equations for the unconstrained best gains.
    static func leastSquares(unit: [[Double]], target: [Double],
                             over range: Range<Int>, bands: Int) -> [Double] {
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: bands + 1),
                                count: bands)
        for row in 0..<bands {
            for column in 0..<bands {
                var sum = 0.0
                for i in range { sum += unit[row][i] * unit[column][i] }
                matrix[row][column] = sum
            }
            // A touch of ridge regularisation. Without it, closely spaced bands are nearly
            // interchangeable and the solver is free to answer with huge opposing gains that
            // cancel — mathematically fine, useless on a real equaliser.
            matrix[row][row] += 1e-3
            var rhs = 0.0
            for i in range { rhs += unit[row][i] * target[i] }
            matrix[row][bands] = rhs
        }
        return solve(matrix, size: bands)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ input: [[Double]], size: Int) -> [Double] {
        var m = input
        for column in 0..<size {
            var pivot = column
            for row in (column + 1)..<size where abs(m[row][column]) > abs(m[pivot][column]) {
                pivot = row
            }
            m.swapAt(column, pivot)
            guard abs(m[column][column]) > 1e-12 else { continue }

            for row in (column + 1)..<size {
                let factor = m[row][column] / m[column][column]
                guard factor != 0 else { continue }
                for k in column...size { m[row][k] -= factor * m[column][k] }
            }
        }

        var result = [Double](repeating: 0, count: size)
        for row in stride(from: size - 1, through: 0, by: -1) {
            guard abs(m[row][row]) > 1e-12 else { continue }
            var value = m[row][size]
            for k in (row + 1)..<size { value -= m[row][k] * result[k] }
            result[row] = value / m[row][row]
        }
        return result
    }

    static func quantise(_ gain: Double, to eq: GraphicEQ) -> Double {
        guard eq.stepDB > 0 else { return gain.clamped(to: eq.gainRange) }
        let steps = ((gain - eq.minGainDB) / eq.stepDB).rounded()
        return (eq.minGainDB + steps * eq.stepDB).clamped(to: eq.gainRange)
    }

    /// Walk each band up and down a step at a time, keeping whatever reduces the error.
    ///
    /// Works against the real filter responses rather than the linear approximation used to get
    /// here, so the answer is exact for the filters the device will actually apply.
    static func refine(_ start: [Double], eq: GraphicEQ, target: [Double],
                       over range: Range<Int>, grid: LogGrid,
                       sampleRate: Double, passes: Int = 4) -> [Double] {
        var gains = start
        var cache: [Int: [Double]] = [:]

        func response(band: Int, gain: Double) -> [Double] {
            let key = band * 100_000 + Int((gain * 100).rounded())
            if let cached = cache[key] { return cached }
            let value = abs(gain) < 1e-9
                ? [Double](repeating: 0, count: grid.count)
                : Biquad(type: .peaking, frequency: eq.frequencies[band], gainDB: gain,
                         q: eq.q(forBandAt: band)).responseDB(on: grid, sampleRate: sampleRate)
            cache[key] = value
            return value
        }

        var total = [Double](repeating: 0, count: grid.count)
        for band in gains.indices {
            let r = response(band: band, gain: gains[band])
            for i in 0..<grid.count { total[i] += r[i] }
        }

        func error(_ combined: [Double]) -> Double {
            var sum = 0.0
            for i in range {
                let d = combined[i] - target[i]
                sum += d * d
            }
            return sum
        }

        var best = error(total)
        for _ in 0..<passes {
            var improved = false
            for band in gains.indices {
                let current = response(band: band, gain: gains[band])
                for delta in [-eq.stepDB, eq.stepDB] {
                    let candidate = quantise(gains[band] + delta, to: eq)
                    guard candidate != gains[band] else { continue }

                    let replacement = response(band: band, gain: candidate)
                    var trial = total
                    for i in 0..<grid.count { trial[i] += replacement[i] - current[i] }

                    let score = error(trial)
                    if score < best - 1e-9 {
                        best = score
                        gains[band] = candidate
                        total = trial
                        improved = true
                        break
                    }
                }
            }
            if !improved { break }
        }
        return gains
    }
}

// MARK: - Common layouts

public extension GraphicEQ {
    /// ISO octave centres, the classic ten-band layout.
    static let tenBand = GraphicEQ(
        name: "10-band (ISO octave)",
        frequencies: [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])

    /// ISO third-octave centres.
    static let thirtyOneBand = GraphicEQ(
        name: "31-band (ISO ⅓ octave)",
        frequencies: [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
                      630, 800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000,
                      6_300, 8_000, 10_000, 12_500, 16_000, 20_000])

    static let fiveBand = GraphicEQ(
        name: "5-band",
        frequencies: [60, 230, 910, 3_600, 14_000], minGainDB: -12, maxGainDB: 12)

    static let sonyWalkman = GraphicEQ(
        name: "Sony Walkman",
        frequencies: [40, 300, 1_000, 3_500, 16_000],
        minGainDB: -10, maxGainDB: 10, stepDB: 1)

    static let sonyHeadphones = GraphicEQ(
        name: "Sony Headphones Connect",
        frequencies: [400, 1_000, 2_500, 6_300, 16_000],
        minGainDB: -10, maxGainDB: 10, stepDB: 1)

    static let presets: [GraphicEQ] = [
        .sonyWalkman, .sonyHeadphones, .fiveBand, .tenBand, .thirtyOneBand
    ]
}

// MARK: - Export

public extension GraphicEQFit {
    /// Settings to enter, one band per line.
    func card(title: String) -> String {
        var out = "\(title)\n\(String(repeating: "=", count: title.count))\n"
        out += "Target: \(eq.name) — \(eq.frequencies.count) bands, "
        out += String(format: "%.0f to %+.0f dB in %.1f dB steps\n\n",
                      eq.minGainDB, eq.maxGainDB, eq.stepDB)

        out += "Band        Set to\n"
        for (index, frequency) in eq.frequencies.enumerated() {
            let label = frequency >= 1_000
                ? String(format: "%.4g kHz", frequency / 1_000)
                : String(format: "%.4g Hz", frequency)
            out += String(format: "%-11@ %+.1f dB\n", label as NSString,
                          index < gains.count ? gains[index] : 0)
        }

        out += String(format: "\nHow close this gets: %.1f dB average error, %.1f dB at worst.\n",
                      rmsErrorDB, maxErrorDB)
        if clipped {
            out += "At least one band is at the end of its range, so the equaliser cannot\n"
            out += "fully reach the correction.\n"
        }
        return out
    }

    /// The `GraphicEQ:` one-liner that Wavelet, Poweramp and others read.
    func graphicEQLine() -> String {
        "GraphicEQ: " + zip(eq.frequencies, gains)
            .map { String(format: "%.0f %.1f", $0, $1) }
            .joined(separator: "; ")
    }
}
