import Foundation

/// Where a filter set came from. Carried into the interchange format so a file found six
/// months later can still be interpreted.
public struct Provenance: Sendable, Codable, Equatable {
    public var tool: String
    public var toolVersion: String
    public var date: Date
    public var microphone: String?
    public var targetCurve: String?
    public var positionsAveraged: Int?
    public var notes: String?

    public init(tool: String = "RoomCurve", toolVersion: String = "1.0",
                date: Date = Date(), microphone: String? = nil,
                targetCurve: String? = nil, positionsAveraged: Int? = nil,
                notes: String? = nil) {
        self.tool = tool
        self.toolVersion = toolVersion
        self.date = date
        self.microphone = microphone
        self.targetCurve = targetCurve
        self.positionsAveraged = positionsAveraged
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case tool
        case toolVersion = "tool_version"
        case date
        case microphone
        case targetCurve = "target_curve"
        case positionsAveraged = "positions_averaged"
        case notes
    }
}

/// A complete correction: a level trim and a cascade of filters.
///
/// This is the canonical representation, and the only one the app stores. Every export format
/// is a short pure function over this struct — which is why there is no format abstraction
/// layer here, just a handful of `to…` methods.
public struct FilterSet: Sendable, Codable, Equatable {
    public var title: String
    /// Level reduction applied ahead of the filters, to leave room for boosts.
    public var preampDB: Double
    public var filters: [Biquad]
    public var provenance: Provenance?

    public init(title: String = "Room Correction", preampDB: Double = 0,
                filters: [Biquad] = [], provenance: Provenance? = nil) {
        self.title = title
        self.preampDB = preampDB
        self.filters = filters
        self.provenance = provenance
    }

    public var active: [Biquad] { filters.filter(\.enabled) }
}

// MARK: - RoomCurve JSON interchange

/// The interchange format.
///
/// Its whole job is to be unambiguous where the established text formats are not. Three things
/// silently corrupt a filter set when moved between tools, and all three are stated explicitly
/// in the file rather than assumed:
///
/// - whether a shelf frequency means the corner or the midpoint of the transition,
/// - what Q means,
/// - whether the preamp is applied before or after the cascade.
///
/// Note what is *not* here: biquad coefficients. Those bake in a sample rate, so storing them
/// would make the file wrong at any other rate. Frequency, gain and Q survive resampling;
/// coefficients are generated at export time for whatever rate the destination runs at.
public struct FilterSetDocument: Sendable, Codable {
    public static let schema = "roomcurve.eq/v1"

    public struct Conventions: Sendable, Codable, Equatable {
        public var shelfFrequency = "centre"
        public var qDefinition = "rbj"
        public var preampPosition = "before_filters"
        public var gainUnits = "dB"

        enum CodingKeys: String, CodingKey {
            case shelfFrequency = "shelf_frequency"
            case qDefinition = "q_definition"
            case preampPosition = "preamp_position"
            case gainUnits = "gain_units"
        }
    }

    public var schema: String
    public var title: String
    public var conventions: Conventions
    public var preampDB: Double
    public var filters: [Biquad]
    public var provenance: Provenance?

    enum CodingKeys: String, CodingKey {
        case schema, title, conventions, filters, provenance
        case preampDB = "preamp_db"
    }

    public init(_ set: FilterSet) {
        schema = Self.schema
        title = set.title
        conventions = Conventions()
        preampDB = set.preampDB
        filters = set.filters
        provenance = set.provenance
    }

    public var filterSet: FilterSet {
        FilterSet(title: title, preampDB: preampDB, filters: filters, provenance: provenance)
    }
}

public extension FilterSet {

    func toJSON() throws -> Data {
        let encoder = JSONEncoder()
        // Without this the schema identifier is written as "roomcurve.eq\/v1", which is valid
        // JSON but needlessly ugly in a file people are meant to read.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(FilterSetDocument(self))
    }

    static func fromJSON(_ data: Data) throws -> FilterSet {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FilterSetDocument.self, from: data).filterSet
    }
}

// MARK: - Text PEQ formats

public extension FilterSet {

    /// AutoEQ / REW `ParametricEQ.txt`. The widest-reach text format — a long list of consumer
    /// apps import it directly.
    func toParametricEQText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        for (i, filter) in active.enumerated() {
            lines.append(String(format: "Filter %d: ON %@ Fc %g Hz Gain %.1f dB Q %.2f",
                                i + 1, filter.type.rawValue,
                                (filter.frequency * 10).rounded() / 10,
                                filter.gainDB, filter.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Equalizer APO `config.txt`.
    func toEqualizerAPOConfig() -> String {
        var lines = ["# \(title)", "# Generated by RoomCurve",
                     String(format: "Preamp: %.1f dB", preampDB)]
        for filter in active {
            lines.append(String(format: "Filter: ON %@ Fc %g Hz Gain %.2f dB Q %.3f",
                                filter.type.rawValue,
                                (filter.frequency * 10).rounded() / 10,
                                filter.gainDB, filter.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parse the AutoEQ / REW / Equalizer APO filter line format.
    ///
    /// Deliberately lenient: it takes any line containing `Fc … Hz` and `Gain … dB`, and ignores
    /// everything else. The various tools disagree on headers, spacing and how many disabled
    /// filler filters they append, but they agree on that.
    static func fromParametricEQText(_ text: String, title: String = "Imported") -> FilterSet {
        var preamp = 0.0
        var filters: [Biquad] = []

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("preamp:") {
                let value = trimmed.dropFirst("preamp:".count)
                    .replacingOccurrences(of: "dB", with: "")
                    .trimmingCharacters(in: .whitespaces)
                preamp = Double(value) ?? 0
                continue
            }
            guard trimmed.lowercased().hasPrefix("filter") else { continue }

            let tokens = trimmed.split(separator: " ").map(String.init)
            guard let fcIndex = tokens.firstIndex(of: "Fc"), fcIndex + 1 < tokens.count,
                  let frequency = Double(tokens[fcIndex + 1]),
                  let gainIndex = tokens.firstIndex(of: "Gain"), gainIndex + 1 < tokens.count,
                  let gain = Double(tokens[gainIndex + 1]) else { continue }

            let enabled = !tokens.contains("OFF")
            let q: Double
            if let qIndex = tokens.firstIndex(of: "Q"), qIndex + 1 < tokens.count {
                q = Double(tokens[qIndex + 1]) ?? 0.707
            } else {
                q = 0.707
            }

            let type: FilterType
            if tokens.contains("LSC") || tokens.contains("LS") { type = .lowShelf }
            else if tokens.contains("HSC") || tokens.contains("HS") { type = .highShelf }
            else { type = .peaking }

            filters.append(Biquad(type: type, frequency: frequency, gainDB: gain,
                                  q: q, enabled: enabled))
        }
        return FilterSet(title: title, preampDB: preamp, filters: filters)
    }
}

// MARK: - Biquad coefficients

public extension FilterSet {

    /// REW / miniDSP biquad coefficient text, for one sample rate.
    ///
    /// Two things about this format bite people. The coefficients are only valid at the sample
    /// rate they were generated for, and there is no field in the file saying what that rate
    /// was — hence the comment header. And the feedback coefficients are written with the
    /// opposite sign to the usual difference equation, which is miniDSP's convention; sending
    /// unflipped values produces a filter that is wrong in a way that still sounds plausible.
    func toBiquadCoefficients(sampleRate: Double) -> String {
        var lines = ["# \(title)",
                     "# Generated by RoomCurve for \(Int(sampleRate)) Hz",
                     "# a1 and a2 are negated, per the miniDSP convention"]
        for (i, filter) in active.enumerated() {
            let c = filter.coefficients(sampleRate: sampleRate)
            lines.append("biquad\(i + 1),")
            lines.append(String(format: "b0=%.10f,", c.b0))
            lines.append(String(format: "b1=%.10f,", c.b1))
            lines.append(String(format: "b2=%.10f,", c.b2))
            lines.append(String(format: "a1=%.10f,", -c.a1))
            lines.append(String(format: "a2=%.10f,", -c.a2))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - CamillaDSP

public extension FilterSet {

    /// CamillaDSP YAML fragment: the filter definitions and the pipeline that applies them.
    func toCamillaDSPYAML(channels: Int = 2) -> String {
        var out = "# \(title)\n# Generated by RoomCurve\nfilters:\n"
        out += "  preamp:\n    type: Gain\n    parameters:\n"
        out += String(format: "      gain: %.2f\n      inverted: false\n", preampDB)

        var names = ["preamp"]
        for (i, filter) in active.enumerated() {
            let name = "band_\(i + 1)"
            names.append(name)
            let type = switch filter.type {
            case .peaking: "Peaking"
            case .lowShelf: "Lowshelf"
            case .highShelf: "Highshelf"
            }
            out += "  \(name):\n    type: Biquad\n    parameters:\n"
            out += "      type: \(type)\n"
            out += String(format: "      freq: %g\n", filter.frequency)
            out += String(format: "      q: %.4f\n", filter.q)
            out += String(format: "      gain: %.2f\n", filter.gainDB)
        }

        out += "pipeline:\n"
        let list = names.joined(separator: ", ")
        for channel in 0..<channels {
            out += "  - type: Filter\n    channel: \(channel)\n    names: [\(list)]\n"
        }
        return out
    }
}

// MARK: - mpv / IINA

public extension FilterSet {

    /// An `af=` line for mpv, which is how IINA applies audio filters.
    ///
    /// FFmpeg's `equalizer` filter is peaking-only, so shelves have to use the separate
    /// `lowshelf` and `highshelf` filters rather than a type flag.
    func toMPVFilterChain() -> String {
        var stages: [String] = []
        if abs(preampDB) > 0.01 {
            stages.append(String(format: "volume=%.2fdB", preampDB))
        }
        for filter in active {
            let name = switch filter.type {
            case .peaking: "equalizer"
            case .lowShelf: "lowshelf"
            case .highShelf: "highshelf"
            }
            stages.append(String(format: "%@=f=%g:t=q:w=%.4f:g=%.2f",
                                 name, filter.frequency, filter.q, filter.gainDB))
        }
        return stages.isEmpty ? "" : "af=" + stages.joined(separator: ",")
    }

    /// The same thing as a drop-in `mpv.conf` snippet.
    func toMPVConf() -> String {
        """
        # \(title)
        # Generated by RoomCurve — append to ~/.config/mpv/mpv.conf
        # (IINA: Preferences → Advanced → Additional options for mpv)
        \(toMPVFilterChain())

        """
    }
}

// MARK: - Manual entry

/// A destination that has no import path, so the user has to type the values in.
public struct ManualEQTarget: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Fixed band centres, for graphic equalisers. Empty means the target is parametric and
    /// the filters can be listed as they are.
    public let bandFrequencies: [Double]
    public let gainRange: ClosedRange<Double>
    public let gainStep: Double
    public let note: String

    public static let sonyWalkman = ManualEQTarget(
        name: "Sony Walkman",
        bandFrequencies: [40, 300, 1_000, 3_500, 16_000],
        gainRange: -10...10, gainStep: 1,
        note: "NW-A / ZX / WM series. No import mechanism exists — enter by hand.")

    public static let sonyHeadphones = ManualEQTarget(
        name: "Sony Headphones Connect",
        bandFrequencies: [400, 1_000, 2_500, 6_300, 16_000],
        gainRange: -10...10, gainStep: 1,
        note: "WH/WF series app. Different band centres from the Walkman. No import.")

    public static let parametricManual = ManualEQTarget(
        name: "Parametric (SoundSource, Roon)",
        bandFrequencies: [], gainRange: -24...24, gainStep: 0.1,
        note: "Enter each filter's frequency, gain and Q into the app's own EQ.")

    public static let all: [ManualEQTarget] = [sonyWalkman, sonyHeadphones, parametricManual]
}

public extension FilterSet {

    /// A card of values to type into a device that cannot import anything.
    ///
    /// For a fixed-band graphic equaliser the cascade's response is sampled at each band centre
    /// and rounded to what the device accepts. That is an approximation and the card says so: a
    /// five-band graphic EQ cannot reproduce a parametric correction, it can only lean the same
    /// way.
    func toManualCard(_ target: ManualEQTarget, grid: LogGrid = .standard,
                      sampleRate: Double = 48_000) -> String {
        var out = "\(title)\n\(String(repeating: "=", count: title.count))\n"
        out += "Target: \(target.name)\n\(target.note)\n\n"

        if target.bandFrequencies.isEmpty {
            out += String(format: "Preamp / volume trim: %.1f dB\n\n", preampDB)
            out += "Filter  Type        Frequency      Gain       Q\n"
            for (i, filter) in active.enumerated() {
                out += String(format: "%-7d %-11s %8.0f Hz %+7.1f dB %6.2f\n",
                              i + 1, (filter.type.label as NSString).utf8String!,
                              filter.frequency, filter.gainDB, filter.q)
            }
            return out
        }

        let response = active.combinedResponseDB(on: grid, sampleRate: sampleRate)
        out += String(format: "Reduce the volume by about %.0f dB to leave headroom.\n\n",
                      abs(preampDB))
        out += "Band       Set to\n"
        for frequency in target.bandFrequencies {
            let index = Int(grid.index(of: frequency).rounded())
            let raw = index >= 0 && index < response.count ? response[index] : 0
            let stepped = (raw / target.gainStep).rounded() * target.gainStep
            let value = stepped.clamped(to: target.gainRange)
            out += String(format: "%6.0f Hz %+6.0f dB\n", frequency, value)
        }
        out += "\nA \(target.bandFrequencies.count)-band graphic equaliser cannot reproduce a "
        out += "parametric correction exactly.\nThese values follow its overall shape.\n"
        return out
    }
}
