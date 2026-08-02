import Foundation

/// Minimal reader and writer for 32-bit float WAV — the format measurement tools exchange
/// impulse responses in.
///
/// ponytail: hand-rolled rather than routed through AVFoundation, for two reasons. It keeps
/// this package free of platform audio frameworks so the whole DSP layer stays testable on any
/// machine without an audio device, and the subset actually needed here (uncompressed float
/// PCM, one or two channels) is small enough that the parsing is shorter than the configuration
/// would be.
public enum WAVFile {

    public struct Audio: Sendable, Equatable {
        public var samples: [Float]
        public var sampleRate: Double
        public var channels: Int

        public init(samples: [Float], sampleRate: Double, channels: Int = 1) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public enum WAVError: Error, LocalizedError {
        case notRIFF
        case unsupportedFormat(Int)
        case missingChunk(String)

        public var errorDescription: String? {
            switch self {
            case .notRIFF: "Not a WAV file."
            case .unsupportedFormat(let code):
                "Unsupported WAV encoding (format \(code)). Expected PCM or 32-bit float."
            case .missingChunk(let name): "WAV file has no \(name) chunk."
            }
        }
    }

    // MARK: - Writing

    public static func encode(_ audio: Audio) -> Data {
        let bytesPerSample = 4
        let dataBytes = audio.samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendUInt32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.appendUInt32(16)
        data.appendUInt16(3) // IEEE float
        data.appendUInt16(UInt16(audio.channels))
        data.appendUInt32(UInt32(audio.sampleRate))
        data.appendUInt32(UInt32(audio.sampleRate) * UInt32(audio.channels * bytesPerSample))
        data.appendUInt16(UInt16(audio.channels * bytesPerSample))
        data.appendUInt16(UInt16(bytesPerSample * 8))

        data.append(contentsOf: Array("data".utf8))
        data.appendUInt32(UInt32(dataBytes))
        for sample in audio.samples {
            data.appendUInt32(sample.bitPattern)
        }
        return data
    }

    // MARK: - Reading

    public static func decode(_ data: Data) throws -> Audio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw WAVError.notRIFF
        }

        var offset = 12
        var format = 0, channels = 1, bitsPerSample = 32
        var sampleRate = 48_000.0
        var sawFormat = false

        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(readUInt32(bytes, offset + 4))
            let body = offset + 8
            guard body + size <= bytes.count || id == "data" else { break }

            switch id {
            case "fmt ":
                format = Int(readUInt16(bytes, body))
                channels = Swift.max(1, Int(readUInt16(bytes, body + 2)))
                sampleRate = Double(readUInt32(bytes, body + 4))
                bitsPerSample = Int(readUInt16(bytes, body + 14))
                sawFormat = true

            case "data":
                guard sawFormat else { throw WAVError.missingChunk("fmt ") }
                let available = Swift.min(size, bytes.count - body)
                let samples = try decodeSamples(bytes, at: body, byteCount: available,
                                                format: format, bitsPerSample: bitsPerSample)
                return Audio(samples: samples, sampleRate: sampleRate, channels: channels)

            default:
                break
            }
            // Chunks are word aligned.
            offset = body + size + (size % 2)
        }
        throw WAVError.missingChunk("data")
    }

    private static func decodeSamples(_ bytes: [UInt8], at offset: Int, byteCount: Int,
                                      format: Int, bitsPerSample: Int) throws -> [Float] {
        switch (format, bitsPerSample) {
        case (3, 32):
            let count = byteCount / 4
            return (0..<count).map {
                Float(bitPattern: readUInt32(bytes, offset + $0 * 4))
            }
        case (1, 24):
            // Recordings from other tools are frequently 24-bit; three bytes little-endian,
            // sign extended from the top byte.
            let count = byteCount / 3
            return (0..<count).map { i in
                let at = offset + i * 3
                guard at + 2 < bytes.count else { return 0 }
                let raw = Int32(bytes[at]) | (Int32(bytes[at + 1]) << 8)
                    | (Int32(bytes[at + 2]) << 16)
                let signed = raw & 0x80_0000 != 0 ? raw | ~0xFF_FFFF : raw
                return Float(signed) / 8_388_608
            }
        case (1, 8):
            return (0..<byteCount).map { Float(Int(bytes[offset + $0]) - 128) / 128 }
        case (1, 16):
            let count = byteCount / 2
            return (0..<count).map {
                Float(Int16(bitPattern: readUInt16(bytes, offset + $0 * 2))) / 32768
            }
        case (1, 32):
            let count = byteCount / 4
            return (0..<count).map {
                Float(Int32(bitPattern: readUInt32(bytes, offset + $0 * 4))) / 2_147_483_648
            }
        default:
            throw WAVError.unsupportedFormat(format)
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

// MARK: - Measurement and filter files

public extension ImpulseResponse {
    /// Impulse response as a 32-bit float mono WAV, peak at 250 ms in a one-second file —
    /// the convention measurement tools expect.
    func wavData() -> Data {
        WAVFile.encode(WAVFile.Audio(samples: samples, sampleRate: sampleRate))
    }

    static func fromWAV(_ data: Data) throws -> ImpulseResponse {
        let audio = try WAVFile.decode(data)
        return ImpulseResponse(samples: audio.samples, sampleRate: audio.sampleRate,
                               acousticDelay: 0, noiseFloor: [], clockDriftPPM: nil)
    }
}

public extension FilterSet {
    /// The correction as an impulse response, for convolution engines.
    ///
    /// - Parameter phaseCentred: FIR filters put the peak in the middle of the file and so
    ///   carry half the filter length as latency. Parametric corrections rendered to an impulse
    ///   response start at the first sample instead, with no added delay.
    func impulseResponseWAV(grid: LogGrid = .standard, sampleRate: Double = 48_000,
                            taps: Int = 24_000, phaseCentred: Bool = true) -> Data {
        let response = active.combinedResponseDB(on: grid, sampleRate: sampleRate)
        let trimmed = response.map { $0 + preampDB }
        var fir = AutoEQ.firFilter(correctionDB: trimmed, grid: grid,
                                   sampleRate: sampleRate, taps: taps)
        if !phaseCentred {
            fir = Array(fir[(taps / 2)...]) + [Float](repeating: 0, count: taps / 2)
        }
        return WAVFile.encode(WAVFile.Audio(samples: fir, sampleRate: sampleRate))
    }
}
