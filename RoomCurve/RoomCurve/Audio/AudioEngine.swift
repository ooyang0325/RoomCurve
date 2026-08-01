import AVFoundation
import Foundation
import RoomCurveKit

/// Which output channels a signal is sent to.
public enum OutputChannel: String, CaseIterable, Codable, Sendable, Hashable {
    case both, left, right

    var label: String {
        switch self {
        case .both: "Both"
        case .left: "Left"
        case .right: "Right"
        }
    }

    func carries(_ channel: Int) -> Bool {
        switch self {
        case .both: true
        case .left: channel == 0
        case .right: channel == 1
        }
    }
}

enum AudioEngineError: Error, LocalizedError {
    case microphonePermissionDenied
    case sessionUnavailable(String)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "RoomCurve needs microphone access to measure your audio system. "
            + "Enable it in Settings › Privacy › Microphone."
        case .sessionUnavailable(let detail): "Could not configure audio: \(detail)"
        case .engineFailed(let detail): "Audio engine failed: \(detail)"
        }
    }
}

/// Where a microphone physically sits on the device.
struct MicrophoneOption: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let dataSourceID: NSNumber?
}

/// Plays the test signal and captures what comes back.
@MainActor
final class AudioEngine: ObservableObject {

    @Published private(set) var routeDescription = "No output"
    @Published private(set) var inputDescription = "—"
    @Published private(set) var isExternalMicrophone = false
    @Published private(set) var availableMicrophones: [MicrophoneOption] = []
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var isRunning = false
    /// Set when the input has been forced back to the built-in microphone after the system
    /// tried to move it somewhere else.
    @Published private(set) var inputWasReclaimed = false

    /// Use an external microphone when one is present. Turning this off matters with USB audio
    /// interfaces, which present themselves as both an input and an output.
    var preferExternalMicrophone = true {
        didSet { try? applyInputPreferences() }
    }

    /// Which built-in microphone to use. Bottom on iPhone, top on iPad, matching where the
    /// device is least likely to be shadowed by a hand.
    var preferredMicrophone: MicrophoneOption? {
        didSet { try? applyInputPreferences() }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let capture = CaptureBuffer()
    private var routeObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeDidChange() }
            }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    // MARK: - Session

    func requestPermission() async throws {
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { throw AudioEngineError.microphonePermissionDenied }
        }
    }

    /// Configure the session for measurement.
    ///
    /// `.measurement` mode is what turns off automatic gain control, noise suppression and echo
    /// cancellation. Without it iOS is quietly reshaping the signal for speech and every
    /// measurement is fiction.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.allowBluetoothA2DP, .allowAirPlay,
                                              .mixWithOthers])
            try session.setPreferredSampleRate(48_000)
            try session.setActive(true)
        } catch {
            throw AudioEngineError.sessionUnavailable(error.localizedDescription)
        }
        sampleRate = session.sampleRate
        try applyInputPreferences()
        refreshRouteInfo()
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Pin the input to the microphone we actually want.
    ///
    /// This is the single most important call in this file. Selecting a Bluetooth output also
    /// moves the *input* to that device's microphone — so measuring a Bluetooth speaker would
    /// silently record through a headset mic and produce a plausible-looking, meaningless
    /// curve. The same thing happens over CarPlay, where input jumps to the car's cabin mic.
    /// Nothing surfaces an error; the only defence is to keep asserting the input we want,
    /// including after every route change.
    func applyInputPreferences() throws {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []

        let builtIn = inputs.first { $0.portType == .builtInMic }
        let external = inputs.first {
            $0.portType == .usbAudio || $0.portType == .headsetMic
        }

        let chosen: AVAudioSessionPortDescription?
        if preferExternalMicrophone, let external {
            chosen = external
            isExternalMicrophone = true
        } else {
            chosen = builtIn
            isExternalMicrophone = false
        }

        guard let chosen else { return }

        let wasWrong = session.currentRoute.inputs.first?.portType != chosen.portType
        try? session.setPreferredInput(chosen)
        if wasWrong && !isExternalMicrophone { inputWasReclaimed = true }

        // Pick the physical capsule, and make sure it is omnidirectional. The front and back
        // microphones can be set to a cardioid pattern, which is wrong for room measurement.
        if chosen.portType == .builtInMic {
            availableMicrophones = (chosen.dataSources ?? []).map {
                MicrophoneOption(name: $0.dataSourceName, dataSourceID: $0.dataSourceID)
            }
            let wanted = preferredMicrophone ?? defaultMicrophone(from: chosen.dataSources ?? [])
            if let wanted,
               let source = chosen.dataSources?.first(where: {
                   $0.dataSourceID == wanted.dataSourceID
               }) {
                if let patterns = source.supportedPolarPatterns,
                   patterns.contains(.omnidirectional) {
                    try? source.setPreferredPolarPattern(.omnidirectional)
                }
                try? chosen.setPreferredDataSource(source)
            }
        } else {
            availableMicrophones = []
        }
        refreshRouteInfo()
    }

    private func defaultMicrophone(from sources: [AVAudioSessionDataSourceDescription])
        -> MicrophoneOption? {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let wantedName = isPad ? "Top" : "Bottom"
        let match = sources.first { $0.dataSourceName.localizedCaseInsensitiveContains(wantedName) }
            ?? sources.first
        guard let match else { return nil }
        return MicrophoneOption(name: match.dataSourceName, dataSourceID: match.dataSourceID)
    }

    private func routeDidChange() {
        // Re-assert the input; a route change is exactly when the system steals it.
        try? applyInputPreferences()
        sampleRate = AVAudioSession.sharedInstance().sampleRate
        refreshRouteInfo()
    }

    private func refreshRouteInfo() {
        let route = AVAudioSession.sharedInstance().currentRoute
        routeDescription = route.outputs.first?.portName ?? "No output"
        inputDescription = route.inputs.first?.portName ?? "—"
    }

    /// True when the input is a car's own microphone, which cannot measure the cabin usefully.
    var isCarPlayInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    func acknowledgeReclaimedInput() { inputWasReclaimed = false }

    // MARK: - Measurement

    /// Play the stimulus and record the result.
    ///
    /// - Parameter externalStimulus: when true nothing is played and the app only listens,
    ///   for systems the phone cannot connect to directly. The analysis is identical either
    ///   way, because the chirp carries the timing.
    func measure(stimulus: SweepStimulus,
                 chirpChannel: OutputChannel = .both,
                 sweepChannel: OutputChannel = .both,
                 externalStimulus: Bool = false,
                 listenFor extraSeconds: Double = 0) async throws -> [Float] {
        let duration = Double(stimulus.samples.count) / stimulus.config.sampleRate
        let signal = externalStimulus ? nil : stereoBuffer(for: stimulus,
                                                          chirpChannel: chirpChannel,
                                                          sweepChannel: sweepChannel)
        // Listening longer than the stimulus covers wireless latency, which can run to seconds.
        let listen = duration + (externalStimulus ? 15 : 3) + extraSeconds
        return try await run(playing: signal, listeningFor: listen)
    }

    /// Start continuous capture, handing every buffer to `onAudio`.
    func startRealTime(noise: PinkNoiseStimulus?,
                       channel: OutputChannel = .both,
                       onAudio: @escaping @Sendable ([Float]) -> Void) throws {
        try configureSession()
        capture.setStreaming(onAudio)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [capture] buffer, _ in
            capture.append(buffer)
        }

        if let noise {
            let buffer = loopingBuffer(samples: noise.samples,
                                       sampleRate: noise.sampleRate, channel: channel)
            engine.connect(player, to: engine.mainMixerNode, format: buffer?.format)
            if let buffer {
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
        }

        engine.prepare()
        do { try engine.start() } catch {
            throw AudioEngineError.engineFailed(error.localizedDescription)
        }
        if noise != nil { player.play() }
        isRunning = true
    }

    func stop() {
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        capture.setStreaming(nil)
        isRunning = false
    }

    // MARK: - Internals

    private func run(playing signal: AVAudioPCMBuffer?,
                     listeningFor seconds: Double) async throws -> [Float] {
        try configureSession()
        capture.reset()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [capture] buffer, _ in
            capture.append(buffer)
        }

        if let signal {
            engine.connect(player, to: engine.mainMixerNode, format: signal.format)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw AudioEngineError.engineFailed(error.localizedDescription)
        }
        isRunning = true

        if let signal {
            player.scheduleBuffer(signal, at: nil, options: [])
            player.play()
        }

        try? await Task.sleep(for: .seconds(seconds))

        stop()
        return capture.drain()
    }

    /// Lay the stimulus into a stereo buffer, honouring the channel each part goes to.
    ///
    /// Sending the chirp and the sweep to different channels is what makes subwoofer alignment
    /// work: the chirp stays on the mains as a fixed time reference while the sweep moves to
    /// the speaker being measured.
    private func stereoBuffer(for stimulus: SweepStimulus,
                              chirpChannel: OutputChannel,
                              sweepChannel: OutputChannel) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: stimulus.config.sampleRate,
                                         channels: 2),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(stimulus.samples.count)),
              let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(stimulus.samples.count)
        let sweepEnd = stimulus.sweepStart + stimulus.sweepLength
        let chirpEnd = stimulus.chirpStart + stimulus.chirp.count
        let closingEnd = stimulus.closingChirpStart + stimulus.chirp.count

        for channel in 0..<2 {
            for i in 0..<stimulus.samples.count {
                let isChirp = (i >= stimulus.chirpStart && i < chirpEnd)
                    || (i >= stimulus.closingChirpStart && i < closingEnd)
                let isSweep = i >= stimulus.sweepStart && i < sweepEnd
                let wanted = isChirp ? chirpChannel.carries(channel)
                    : isSweep ? sweepChannel.carries(channel) : true
                channels[channel][i] = wanted ? stimulus.samples[i] : 0
            }
        }
        return buffer
    }

    private func loopingBuffer(samples: [Float], sampleRate: Double,
                               channel: OutputChannel) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for c in 0..<2 {
            for i in 0..<samples.count {
                channels[c][i] = channel.carries(c) ? samples[i] : 0
            }
        }
        return buffer
    }
}

/// Collects captured audio off the render thread.
///
/// The tap callback runs on a realtime audio thread, so it must not allocate unpredictably or
/// touch the main actor. A lock around an array is the boring option and is fast enough at
/// buffer granularity.
private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var streaming: (@Sendable ([Float]) -> Void)?

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(48_000 * 20)
    }

    func setStreaming(_ handler: (@Sendable ([Float]) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        streaming = handler
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        // Take the first channel; the microphone is mono even when the format is not.
        let chunk = Array(UnsafeBufferPointer(start: data[0], count: count))

        lock.lock()
        let handler = streaming
        if handler == nil { samples.append(contentsOf: chunk) }
        lock.unlock()

        handler?(chunk)
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}

#if canImport(UIKit)
import UIKit
#endif
