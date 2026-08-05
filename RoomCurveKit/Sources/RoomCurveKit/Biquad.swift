import Foundation

/// Filter shapes, named with the codes REW, AutoEQ and Equalizer APO all use.
///
/// The shelf codes are deliberately `LSC`/`HSC` rather than `LS`/`HS`. Those are *different
/// filters*: `LS`/`HS` place the given frequency at the shelf's corner, `LSC`/`HSC` place it at
/// the midpoint of the transition. Feed the same numbers to the wrong one and the correction
/// silently lands in the wrong place. RBJ's shelving formulae are midpoint-based, so `LSC`/`HSC`
/// is what this codebase means everywhere, and what the exporters declare.
public enum FilterType: String, Sendable, Codable, CaseIterable, Hashable {
    case peaking = "PK"
    case lowShelf = "LSC"
    case highShelf = "HSC"

    public var label: String {
        switch self {
        case .peaking: "Peak"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        }
    }
}

/// Which channel a filter applies to.
public enum FilterChannel: String, Sendable, Codable, CaseIterable, Hashable {
    case both, left, right

    public var label: String {
        switch self {
        case .both: "Both"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// One parametric filter, stored the only way that stays portable: as frequency, gain and Q.
///
/// Never as coefficients. Biquad coefficients bake in the sample rate, so a set computed at
/// 48 kHz is quietly wrong at 96 kHz. Coefficients are generated at export time, for the rate
/// the destination actually runs at.
public struct Biquad: Sendable, Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var type: FilterType
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool
    public var channel: FilterChannel

    enum CodingKeys: String, CodingKey {
        case id, type, q, enabled, channel
        case frequency = "fc_hz"
        case gainDB = "gain_db"
    }

    public init(id: UUID = UUID(), type: FilterType = .peaking, frequency: Double,
                gainDB: Double, q: Double, enabled: Bool = true,
                channel: FilterChannel = .both) {
        self.id = id
        self.type = type
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
        self.channel = channel
    }

    /// Q expressed as bandwidth in octaves — what AUNBandEQ and some hardware want instead.
    public var bandwidthInOctaves: Double {
        guard q > 0 else { return 0 }
        return 2 / Foundation.log(2.0) * asinh(1 / (2 * q))
    }

    public static func q(fromBandwidthInOctaves bw: Double) -> Double {
        guard bw > 0 else { return 1 }
        return 1 / (2 * sinh(Foundation.log(2.0) / 2 * bw))
    }

    /// How long this filter rings, as the time for it to decay by 60 dB.
    ///
    /// A high-Q boost is a resonator. REW refuses to create boost filters whose decay runs past
    /// roughly 500 ms, because such a filter adds its own ringing to the room instead of
    /// removing the room's. Used by the automatic equaliser to cap boost Q.
    public var decayTime60dB: Double {
        guard frequency > 0, q > 0 else { return 0 }
        return (q * 6.91) / (Double.pi * frequency)
    }
}

/// Direct-form biquad coefficients, normalised so a0 = 1.
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0, b1, b2, a1, a2: Double

    /// The difference equation these belong to is
    /// `y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]`
    ///
    /// Note the **minus** signs on the feedback terms. miniDSP and REW's coefficient export use
    /// the opposite sign for a1 and a2; that flip happens in the exporter, not here.
    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Response at one frequency, evaluating H(z) on the unit circle.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)

        let numeratorReal = b0 + b1 * cos1 + b2 * cos2
        let numeratorImag = -(b1 * sin1 + b2 * sin2)
        let denominatorReal = 1 + a1 * cos1 + a2 * cos2
        let denominatorImag = -(a1 * sin1 + a2 * sin2)

        let numerator = (numeratorReal * numeratorReal + numeratorImag * numeratorImag).squareRoot()
        let denominator = (denominatorReal * denominatorReal
                           + denominatorImag * denominatorImag).squareRoot()
        guard denominator > 0 else { return 0 }
        return 20 * Foundation.log10(numerator / denominator)
    }

    /// Run these coefficients over a signal using the difference equation documented above.
    public func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        for i in samples.indices {
            let x = Double(samples[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = Float(y)
            x2 = x1; x1 = x
            y2 = y1; y1 = y
        }
        return output
    }
}

public extension Biquad {

    /// Coefficients from the RBJ Audio EQ Cookbook, for a given sample rate.
    func coefficients(sampleRate: Double) -> BiquadCoefficients {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * Swift.min(frequency, sampleRate / 2 - 1) / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * Swift.max(q, 0.01))
        let sqrtA = A.squareRoot()

        var b0, b1, b2, a0, a1, a2: Double

        switch type {
        case .peaking:
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha

        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (A + 1) - (A - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - 2 * sqrtA * alpha
        }

        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0,
                                  a1: a1 / a0, a2: a2 / a0)
    }

    /// This filter's magnitude response across the shared grid, in dB.
    func responseDB(on grid: LogGrid = .standard, sampleRate: Double = 48_000) -> [Double] {
        guard enabled else { return [Double](repeating: 0, count: grid.count) }
        let c = coefficients(sampleRate: sampleRate)
        return grid.frequencies.map { c.magnitudeDB(at: $0, sampleRate: sampleRate) }
    }
}

public extension Array where Element == Biquad {
    /// Combined response of a cascade of filters, in dB — they simply sum.
    func combinedResponseDB(on grid: LogGrid = .standard,
                            sampleRate: Double = 48_000) -> [Double] {
        var total = [Double](repeating: 0, count: grid.count)
        for filter in self where filter.enabled {
            let response = filter.responseDB(on: grid, sampleRate: sampleRate)
            for i in 0..<grid.count { total[i] += response[i] }
        }
        return total
    }

    /// Apply the same RBJ cascade exported to a parametric equaliser.
    func process(_ samples: [Float], sampleRate: Double) -> [Float] {
        reduce(samples) { signal, filter in
            filter.enabled ? filter.coefficients(sampleRate: sampleRate).process(signal) : signal
        }
    }
}
