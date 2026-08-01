import SwiftUI
import RoomCurveKit

struct MeasureSetupView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sweep") {
                    LabeledContent("Length") {
                        Text(String(format: "%.1f s", state.sweepConfig.duration))
                    }
                    Slider(value: $state.sweepConfig.duration, in: 1...10, step: 0.5)
                    Text("Longer sweeps hear further into the noise. Shorter sweeps suffer "
                         + "less from the phone and a wireless speaker running on separate "
                         + "clocks, which smears high-frequency phase.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Channels") {
                    Picker("Chirp", selection: $state.chirpChannel) {
                        ForEach(OutputChannel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Sweep", selection: $state.sweepChannel) {
                        ForEach(OutputChannel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text("Keep the chirp on one fixed speaker and move the sweep to the "
                         + "speaker being measured. The chirp is the shared time reference "
                         + "that makes phase comparable between measurements.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Remove delay", isOn: $state.removeDelay)
                    Text(state.removeDelay
                         ? "Arrival time is discarded so measurements average cleanly."
                         : "Arrival time is kept, which is what time alignment needs.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("External stimulus", isOn: $state.externalStimulus)
                    Text("Play the test signal from the system itself and let RoomCurve only "
                         + "listen. Use this when the phone cannot connect directly, or when "
                         + "a wireless connection keeps failing.")
                    .font(.caption).foregroundStyle(.secondary)
                    if state.externalStimulus {
                        Text("Export the file below, then tap Measure and play it whenever you "
                             + "are ready. RoomCurve waits for the signal to start rather than "
                             + "listening for a fixed time, so there is nothing to race.")
                        .font(.caption).foregroundStyle(.secondary)
                        Text("Re-export whenever you change the sweep length or channels — the "
                             + "file and the app have to describe the same signal.")
                        .font(.caption).foregroundStyle(.orange)
                    }
                    if state.externalStimulus {
                        Button("Export test signal…") { exportStimulus() }
                    }
                }

                Section("Microphone") {
                    Toggle("Use external microphone when connected",
                           isOn: Binding(get: { audio.preferExternalMicrophone },
                                         set: { audio.preferExternalMicrophone = $0 }))
                    if !audio.availableMicrophones.isEmpty {
                        Picker("Built-in microphone", selection: Binding(
                            get: { audio.preferredMicrophone ?? audio.availableMicrophones[0] },
                            set: { audio.preferredMicrophone = $0 })) {
                            ForEach(audio.availableMicrophones) { Text($0.name).tag($0) }
                        }
                    }
                    LabeledContent("In use", value: audio.inputDescription)
                    Text("Point the microphone at the speaker. The phone's own body shadows it "
                         + "by several dB above 3 kHz.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Calibration") {
                    Toggle("Apply calibration", isOn: $state.applyCalibration)
                    Picker("Calibration", selection: $state.calibrationName) {
                        ForEach(store.calibrations) { calibration in
                            Text(calibration.name).tag(calibration.name)
                        }
                    }
                    .disabled(!state.applyCalibration)
                    if let calibration = store.calibrations
                        .first(where: { $0.name == state.calibrationName }) {
                        if calibration.isEstimate {
                            Label("This curve is an estimate, not a measurement of a real "
                                  + "microphone.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                        }
                        if let source = calibration.source {
                            Text("Source: \(source)").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let notes = calibration.notes {
                            Text(notes).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Measure Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(get: { exporting.map(ShareItem.init) },
                                 set: { _ in exporting = nil })) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func exportStimulus() {
        var config = state.sweepConfig
        config.sampleRate = 48_000
        let stimulus = SweepGenerator.make(config)
        // Two channels so the chirp and sweep channel settings survive into the file.
        var interleaved = [Float](repeating: 0, count: stimulus.samples.count * 2)
        let sweepEnd = stimulus.sweepStart + stimulus.sweepLength
        let chirpEnd = stimulus.chirpStart + stimulus.chirp.count
        let closingEnd = stimulus.closingChirpStart + stimulus.chirp.count
        for i in 0..<stimulus.samples.count {
            let isChirp = (i >= stimulus.chirpStart && i < chirpEnd)
                || (i >= stimulus.closingChirpStart && i < closingEnd)
            let isSweep = i >= stimulus.sweepStart && i < sweepEnd
            for channel in 0..<2 {
                let wanted = isChirp ? state.chirpChannel.carries(channel)
                    : isSweep ? state.sweepChannel.carries(channel) : true
                interleaved[i * 2 + channel] = wanted ? stimulus.samples[i] : 0
            }
        }
        let data = WAVFile.encode(WAVFile.Audio(samples: interleaved,
                                                sampleRate: config.sampleRate, channels: 2))
        exporting = try? store.temporaryFile(named: "RoomCurve Test Signal.wav", contents: data)
    }
}

struct PlotSetupView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var manualLevel = 75.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Target curve") {
                    Picker("Curve", selection: $state.selectedTargetName) {
                        ForEach(store.targetCurves) { Text($0.name).tag($0.name) }
                    }
                    Picker("Fit", selection: Binding(
                        get: { isAutomatic },
                        set: { state.curveFit = $0 ? .automatic : .manual(manualLevel) })) {
                        Text("Automatic").tag(true)
                        Text("Manual").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if !isAutomatic {
                        LabeledContent("Level") {
                            Text(String(format: "%.0f dB", manualLevel))
                        }
                        Slider(value: Binding(get: { manualLevel },
                                              set: { manualLevel = $0
                                                     state.curveFit = .manual($0) }),
                               in: 30...100, step: 1)
                        Text("A fixed level stops the curve shifting between measurements, "
                             + "which matters when comparing one adjustment against the next.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Display") {
                    Picker("Smoothing", selection: $state.smoothing) {
                        ForEach(Smoothing.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Plot mode", selection: $state.plotMode) {
                        ForEach(PlotMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(state.plotMode == .average
                         ? "Averages measurements as they are captured — use this for tuning "
                         + "towards a target."
                         : "Draws the newest over the previous ones — use this to see what an "
                         + "adjustment did.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Signal to noise") {
                    Toggle("Hide unreliable regions", isOn: $state.blankingEnabled)
                    if state.blankingEnabled {
                        LabeledContent("Threshold") {
                            Text(String(format: "%.0f dB", state.snrThreshold))
                        }
                        Slider(value: $state.snrThreshold, in: 0...30, step: 1)
                        Text("Frequencies with less signal than this are left out. It is also "
                             + "an honest picture of where a speaker stops producing output.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Compare with") {
                    Picker("Saved measurement", selection: $state.comparisonMeasurement) {
                        Text("None").tag(SavedMeasurement?.none)
                        ForEach(store.measurements) { measurement in
                            Text(measurement.name).tag(SavedMeasurement?.some(measurement))
                        }
                    }
                }
            }
            .navigationTitle("Plot Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var isAutomatic: Bool {
        if case .automatic = state.curveFit { return true }
        return false
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
    init(_ url: URL) { self.url = url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
