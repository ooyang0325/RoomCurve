import Foundation

/// What kind of correction to generate.
public enum CorrectionKind: String, Sendable, Codable, CaseIterable {
    case parametric = "PEQ"
    case fir = "FIR"

    public var label: String {
        switch self {
        case .parametric: "Parametric EQ"
        case .fir: "FIR filter"
        }
    }
}

public struct EQSettings: Sendable, Codable, Equatable {
    public var kind: CorrectionKind
    public var minFrequency: Double
    public var maxFrequency: Double
    /// Largest boost or cut a single filter may apply.
    public var maxGainDB: Double
    /// Refuse to generate boosts at all. The safe choice when headroom is tight; pair it with
    /// lowering the target curve so the correction still has somewhere to go.
    public var allowOnlyCuts: Bool
    public var maxFilters: Int
    public var maxQ: Double
    public var allowShelfFilters: Bool
    /// Ceiling on the boost of the *combined* correction.
    ///
    /// Capping each filter individually is not enough: nothing stops the algorithm stacking
    /// several filters at neighbouring frequencies and boosting far past the per-filter limit.
    /// That is how a deep, narrow null ends up getting a large boost despite every guard on the
    /// individual filters. Defaults to the per-filter limit.
    public var maxTotalBoostDB: Double
    /// Regions below this signal-to-noise are left alone.
    public var snrThreshold: Double

    public init(kind: CorrectionKind = .parametric,
                minFrequency: Double = 20,
                maxFrequency: Double = 500,
                maxGainDB: Double = 6,
                allowOnlyCuts: Bool = false,
                maxFilters: Int = 10,
                maxQ: Double = 10,
                allowShelfFilters: Bool = true,
                maxTotalBoostDB: Double? = nil,
                snrThreshold: Double = 10) {
        self.kind = kind
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.maxGainDB = maxGainDB
        self.allowOnlyCuts = allowOnlyCuts
        self.maxFilters = maxFilters
        self.maxQ = maxQ
        self.allowShelfFilters = allowShelfFilters
        self.maxTotalBoostDB = maxTotalBoostDB ?? maxGainDB
        self.snrThreshold = snrThreshold
    }
}

/// The outcome of an automatic correction.
public struct Correction: Sendable {
    public let filters: [Biquad]
    /// Combined filter response, in dB, on the grid.
    public let filterResponseDB: [Double]
    /// What the system should measure once the correction is applied.
    public let predictedDB: [Double]
    /// Level reduction needed to keep the correction from clipping.
    public let preampDB: Double
    /// Largest boost anywhere in the correction — worth showing, since it is the number that
    /// tells the user how much headroom the correction just consumed.
    public let maxBoostDB: Double
}

public enum AutoEQ {

    /// Longest a boost filter may ring, in seconds.
    ///
    /// A boost is a resonator; give it enough Q and it adds its own ringing to the room rather
    /// than removing the room's. Capping decay at half a second is REW's rule and it also,
    /// conveniently, does most of the work of the "never boost a narrow dip" rule — narrow dips
    /// demand exactly the high-Q boosts this rejects.
    static let maximumBoostDecay = 0.5

    static let qCandidates: [Double] = [0.5, 0.7, 1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.3, 16.0]
    static let shelfQCandidates: [Double] = [0.5, 0.707, 0.9]
    static let gainScales: [Double] = [0.5, 0.75, 1.0, 1.25]

    /// Generate a correction that moves `measured` towards `target`.
    ///
    /// Greedy: repeatedly find the frequency furthest from target and place the filter that
    /// most reduces the total squared error, until the filters run out or nothing is left worth
    /// correcting. Each filter is chosen by brute-force search over a small grid of shapes,
    /// which needs no optimiser and cannot fail to converge.
    public static func correct(measuredDB: [Double],
                               targetDB: [Double],
                               snrDB: [Double],
                               settings: EQSettings,
                               grid: LogGrid = .standard,
                               sampleRate: Double = 48_000) -> Correction {
        let range = grid.indices(from: settings.minFrequency, to: settings.maxFrequency)
        var usable = [Bool](repeating: false, count: grid.count)
        for i in range where i < snrDB.count {
            usable[i] = snrDB[i] >= settings.snrThreshold
        }

        // Positive error means the measurement sits below target and wants a boost.
        var residual = (0..<grid.count).map { targetDB[$0] - measuredDB[$0] }
        var filters: [Biquad] = []
        var total = [Double](repeating: 0, count: grid.count)

        for _ in 0..<settings.maxFilters {
            guard let worst = worstIndex(residual, usable: usable) else { break }
            let candidates = candidateFilters(at: grid.frequencies[worst],
                                              error: residual[worst],
                                              settings: settings, grid: grid)
            guard !candidates.isEmpty else { break }

            let before = squaredError(residual, usable: usable)
            var best: (filter: Biquad, response: [Double], error: Double)?

            for candidate in candidates {
                let response = candidate.responseDB(on: grid, sampleRate: sampleRate)

                // Reject anything that would push the cascade past the overall boost ceiling.
                var exceedsCeiling = false
                for i in 0..<grid.count where total[i] + response[i] > settings.maxTotalBoostDB {
                    exceedsCeiling = true
                    break
                }
                if exceedsCeiling { continue }

                let trial = (0..<grid.count).map { residual[$0] - response[$0] }
                let error = squaredError(trial, usable: usable)
                if best == nil || error < best!.error {
                    best = (candidate, response, error)
                }
            }

            guard let winner = best, winner.error < before * 0.999 else { break }
            filters.append(winner.filter)
            for i in 0..<grid.count {
                residual[i] -= winner.response[i]
                total[i] += winner.response[i]
            }
        }

        let response = filters.combinedResponseDB(on: grid, sampleRate: sampleRate)
        let predicted = (0..<grid.count).map { measuredDB[$0] + response[$0] }
        let maxBoost = response.max() ?? 0

        return Correction(filters: filters,
                          filterResponseDB: response,
                          predictedDB: predicted,
                          preampDB: -Swift.max(0, maxBoost),
                          maxBoostDB: maxBoost)
    }

    // MARK: - Steps

    static func worstIndex(_ residual: [Double], usable: [Bool]) -> Int? {
        var best: Int?
        var magnitude = 0.5 // below this there is nothing worth spending a filter on
        for i in 0..<residual.count where usable[i] {
            if abs(residual[i]) > magnitude {
                magnitude = abs(residual[i])
                best = i
            }
        }
        return best
    }

    static func squaredError(_ residual: [Double], usable: [Bool]) -> Double {
        var total = 0.0
        for i in 0..<residual.count where usable[i] { total += residual[i] * residual[i] }
        return total
    }

    /// Every filter shape worth trying at one frequency.
    static func candidateFilters(at frequency: Double, error: Double,
                                 settings: EQSettings, grid: LogGrid) -> [Biquad] {
        guard !(settings.allowOnlyCuts && error > 0) else { return [] }

        var candidates: [Biquad] = []
        let maxQ = Swift.max(0.5, settings.maxQ)

        for q in qCandidates where q <= maxQ {
            for scale in gainScales {
                let gain = (error * scale).clamped(to: -settings.maxGainDB...settings.maxGainDB)
                guard abs(gain) > 0.1 else { continue }
                if settings.allowOnlyCuts && gain > 0 { continue }
                let filter = Biquad(type: .peaking, frequency: frequency, gainDB: gain, q: q)
                // Boosts may not be allowed to ring.
                if gain > 0 && filter.decayTime60dB > maximumBoostDecay { continue }
                candidates.append(filter)
            }
        }

        // Shelves only make sense pointing off the end of the corrected band, where a single
        // one can replace several peaking filters.
        if settings.allowShelfFilters {
            let lowEdge = settings.minFrequency * 4
            let highEdge = settings.maxFrequency / 4
            for q in shelfQCandidates {
                for scale in gainScales {
                    let gain = (error * scale).clamped(to: -settings.maxGainDB...settings.maxGainDB)
                    guard abs(gain) > 0.1 else { continue }
                    if settings.allowOnlyCuts && gain > 0 { continue }
                    if frequency <= lowEdge {
                        candidates.append(Biquad(type: .lowShelf, frequency: frequency,
                                                 gainDB: gain, q: q))
                    }
                    if frequency >= highEdge {
                        candidates.append(Biquad(type: .highShelf, frequency: frequency,
                                                 gainDB: gain, q: q))
                    }
                }
            }
        }
        return candidates
    }
}

// MARK: - FIR

public extension AutoEQ {

    /// Build a linear-phase FIR filter that applies `correctionDB`.
    ///
    /// ponytail: linear phase, meaning magnitude is corrected and phase is left alone. Mixed
    /// phase is what the good commercial room-correction systems use — minimum phase in the
    /// modal region, linear above it — because linear phase everywhere costs pre-ringing, half
    /// the filter length ahead of every transient. Upgrade path is to compute the minimum-phase
    /// version by cepstrum and blend the two by frequency. Linear phase is correct in magnitude
    /// today, which is what a room correction is mostly for.
    ///
    /// - Returns: `taps` samples with the peak at the centre.
    static func firFilter(correctionDB: [Double],
                          grid: LogGrid = .standard,
                          sampleRate: Double = 48_000,
                          taps: Int = 24_000) -> [Float] {
        let fftLength = FFTProcessor.length(atLeast: taps * 2)
        let fft = FFTProcessor(length: fftLength)
        let binSpacing = sampleRate / Double(fftLength)
        let half = fftLength / 2

        // Desired magnitude per bin, tapering to unity outside the grid so the filter does not
        // invent correction where nothing was measured.
        var magnitude = [Double](repeating: 1, count: half + 1)
        for k in 0...half {
            let frequency = Double(k) * binSpacing
            if frequency < grid.fMin || frequency > grid.fMax {
                magnitude[k] = 1
                continue
            }
            let position = grid.index(of: frequency)
            let i = Int(position)
            let t = position - Double(i)
            let dB: Double
            if i + 1 < correctionDB.count {
                dB = correctionDB[i] * (1 - t) + correctionDB[i + 1] * t
            } else {
                dB = correctionDB[Swift.min(i, correctionDB.count - 1)]
            }
            magnitude[k] = linear(fromDB: dB)
        }

        // Zero phase, Hermitian symmetric — an even, real spectrum gives an even, real filter.
        var spectrum = Spectrum(count: fftLength)
        for k in 0...half {
            spectrum.real[k] = Float(magnitude[k])
            if k > 0 && k < half { spectrum.real[fftLength - k] = Float(magnitude[k]) }
        }

        let time = fft.inverse(spectrum)

        // The response is centred on sample zero and wraps; rotate it to the middle and window.
        var out = [Float](repeating: 0, count: taps)
        let centre = taps / 2
        for i in 0..<taps {
            let offset = i - centre
            let source = offset >= 0 ? offset : fftLength + offset
            if source >= 0 && source < time.count { out[i] = time[source] }
        }
        SweepGenerator.applyFades(&out, seconds: Double(taps) / 4 / sampleRate,
                                  sampleRate: sampleRate)
        return out
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
