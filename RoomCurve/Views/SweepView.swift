import SwiftUI
import RoomCurveKit

struct SweepView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioEngine

    @State private var plotKind: PlotKind = .magnitude
    @State private var low = 20.0
    @State private var high = 20_000.0
    @State private var measuring = false
    @State private var showMeasureSetup = false
    @State private var showPlotSetup = false
    @State private var saveName = ""
    @State private var showSave = false
    @State private var task: Task<Void, Never>?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Landscape on a phone. The plot wants every pixel of height it can get, so the chrome
    /// has to stop taking a horizontal slice out of it and float on top instead.
    private var isShort: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isShort {
                // The bar floats over the plot, so the plot gives back just enough room at the
                // bottom for the frequency labels to stay readable underneath it.
                plot
                    .padding(.trailing, 74)
                    .overlay(alignment: .trailing) { controls.padding(.trailing, 6) }
            } else {
                VStack(spacing: 0) {
                    statusStrip
                    plot
                    toolbar
                }
            }
        }
        .navigationTitle("Sweep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // In landscape the plot selector moves up into the bar rather than costing a row.
            if isShort {
                ToolbarItem(placement: .principal) {
                    plotPicker.frame(width: 300)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                RoutePickerButton().frame(width: 40, height: 40)
            }
        }
        .sheet(isPresented: $showMeasureSetup) { MeasureSetupView() }
        .sheet(isPresented: $showPlotSetup) { PlotSetupView() }
        .alert("Save measurement", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }
        } message: {
            Text(state.plotMode == .average
                 ? "Saves the average of \(state.captures.count) measurements."
                 : "Saves the most recent measurement.")
        }
        .onDisappear { task?.cancel(); audio.stop() }
    }

    // MARK: - Pieces

    private var statusStrip: some View {
        VStack(spacing: 2) {
            if let status = state.status {
                Text(status)
                    .font(.footnote)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let drift = state.lastClockDriftPPM, abs(drift) > 200 {
                Label(String(format: "Clock drift %.0f ppm — phase above a few kHz may be "
                             + "smeared. A shorter sweep or a wired connection helps.", drift),
                      systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if audio.inputWasReclaimed {
                Label("Input was switched away and has been set back to the built-in "
                      + "microphone.", systemImage: "mic.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, state.status == nil ? 0 : 6)
        .animation(.spring(duration: 0.3, bounce: 0), value: state.status)
    }

    private var plot: some View {
        ResponsePlot(series: series, kind: plotKind, grid: state.grid,
                     lowFrequency: $low, highFrequency: $high)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            if state.captures.isEmpty {
                ContentUnavailableView(
                    "No measurements",
                    systemImage: "waveform.path",
                    description: Text("Set the volume low, tap Measure, then raise the volume "
                                      + "until the sweep is clearly audible."))
                .allowsHitTesting(false)
            }
        }
        .gesture(pagingGesture)
    }

    /// Swiping from the edge moves between magnitude, phase and group delay.
    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 2 else {
                    return
                }
                let all = PlotKind.allCases
                guard let index = all.firstIndex(of: plotKind) else { return }
                let next = value.translation.width < 0 ? index + 1 : index - 1
                guard all.indices.contains(next) else { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { plotKind = all[next] }
            }
    }

    private var plotPicker: some View {
        Picker("Plot", selection: $plotKind) {
            ForEach(PlotKind.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            plotPicker.padding(.horizontal)
            controls
            counts
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// A row along the bottom in portrait, a rail down the right in landscape.
    ///
    /// The rail keeps the whole plot height and, unlike a bar across the bottom, never sits on
    /// top of the frequency labels.
    private var controlLayout: AnyLayout {
        isShort ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 18))
    }

    private var controls: some View {
        GlassGroup {
                controlLayout {
                    button("gearshape", "Measure setup") { showMeasureSetup = true }
                    button("chart.xyaxis.line", "Plot setup") { showPlotSetup = true }

                    Button {
                        measuring ? cancel() : measure()
                    } label: {
                        Group {
                            if measuring {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "waveform.badge.magnifyingglass")
                                    .font(.title3)
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .tint(measuring ? .red : .accentColor)
                    .prominentAction()
                    .accessibilityLabel(measuring ? "Stop measuring" : "Measure")

                    button("arrow.uturn.backward", "Undo") { state.undoCapture() }
                        .disabled(state.captures.isEmpty)
                    button("square.and.arrow.down", "Save") {
                        saveName = defaultName()
                        showSave = true
                    }
                    .disabled(state.captures.isEmpty)
                }
                .floatingBar()
        }
    }

    private var counts: some View {
        HStack {
            Text(state.captures.isEmpty
                 ? "Ready" : "\(state.captures.count) measurement"
                 + (state.captures.count == 1 ? "" : "s"))
            Spacer()
            Button("Reset") { state.resetCaptures() }
                .disabled(state.captures.isEmpty)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
    }

    private func button(_ icon: String, _ label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 30, height: 30)
        }
        .secondaryAction()
        .accessibilityLabel(label)
    }

    // MARK: - Series

    private var series: [PlotSeries] {
        var result: [PlotSeries] = []
        let grid = state.grid

        if plotKind == .magnitude {
            result.append(PlotSeries(id: "target", values: state.fittedTarget(from: store),
                                     color: .yellow, lineWidth: 2, band: 3))
        } else {
            result.append(PlotSeries(id: "zero",
                                     values: [Double](repeating: 0, count: grid.count),
                                     color: .yellow, lineWidth: 1))
        }

        if let comparison = state.comparisonMeasurement,
           let ir = try? comparison.load() {
            let response = Analyser.response(of: ir).smoothed(state.smoothing)
            result.append(PlotSeries(id: "saved", values: values(of: response),
                                     color: .gray, lineWidth: 1.5,
                                     blanked: state.blanked(for: response)))
        }

        // Older captures fade back so the newest reads as the current one.
        if state.plotMode == .history {
            for (index, capture) in state.captures.enumerated().dropLast() {
                let age = Double(state.captures.count - index)
                let smoothed = capture.smoothed(state.smoothing)
                result.append(PlotSeries(id: "history-\(index)", values: values(of: smoothed),
                                         color: .green, lineWidth: 1,
                                         blanked: state.blanked(for: smoothed),
                                         opacity: max(0.12, 0.6 / age)))
            }
        } else if state.captures.count > 1 {
            for (index, capture) in state.captures.enumerated() {
                let smoothed = capture.smoothed(state.smoothing)
                result.append(PlotSeries(id: "member-\(index)", values: values(of: smoothed),
                                         color: .green, lineWidth: 0.8,
                                         blanked: state.blanked(for: smoothed),
                                         opacity: 0.22))
            }
        }

        if let current = state.currentResponse {
            result.append(PlotSeries(id: "current", values: values(of: current),
                                     color: .green, lineWidth: 2.5,
                                     blanked: state.blanked(for: current)))
        }
        return result
    }

    private func values(of response: FrequencyResponse) -> [Double] {
        switch plotKind {
        case .magnitude: response.magnitudeDB
        case .phase: response.phaseDegrees
        case .groupDelay: response.groupDelayMS
        }
    }

    // MARK: - Actions

    private func measure() {
        measuring = true
        state.show(state.externalStimulus
                   ? "Listening — play the test signal whenever you are ready"
                   : "Measuring…")

        task = Task {
            defer { measuring = false }
            do {
                var config = state.sweepConfig
                config.sampleRate = audio.sampleRate
                let stimulus = SweepGenerator.make(config)

                let recording: [Float]
                if state.externalStimulus {
                    recording = try await listenForExternalSignal(stimulus: stimulus)
                } else {
                    recording = try await audio.measure(
                        stimulus: stimulus,
                        chirpChannel: state.chirpChannel,
                        sweepChannel: state.sweepChannel)
                }

                guard !Task.isCancelled else { return }

                let ir = try Deconvolver.analyse(recording: recording, stimulus: stimulus,
                                                 removeDelay: state.removeDelay)
                let response = Analyser.response(of: ir)
                state.lastImpulseResponse = ir
                state.lastClockDriftPPM = ir.clockDriftPPM
                state.addCapture(state.calibrated(response, store: store))
                state.show("Measurement captured")
            } catch is CancellationError {
                // Nothing to report; the user stopped it.
            } catch {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    /// Wait for somebody to press play, then capture the rest of the signal.
    ///
    /// Rather than record for a fixed window and hope it overlaps with whatever the other
    /// device is doing, this listens indefinitely and watches for the moment the room stops
    /// being quiet. Once the signal starts it keeps recording exactly long enough to hold a
    /// complete measurement, then stops on its own.
    private func listenForExternalSignal(stimulus: SweepStimulus) async throws -> [Float] {
        try audio.startListening()
        defer { audio.stop() }

        let sampleRate = audio.sampleRate
        let needed = stimulus.samplesNeededAfterOnset
        var onset: Int?

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(200))
            let captured = audio.capturedSamples()

            if onset == nil {
                onset = SignalOnset.find(in: captured, sampleRate: sampleRate)
                if onset != nil { state.show("Test signal detected — capturing") }
                continue
            }
            guard let onset else { continue }

            if captured.count >= onset + needed {
                return captured
            }
        }
        throw CancellationError()
    }

    private func cancel() {
        task?.cancel()
        audio.stop()
        measuring = false
        state.show("Stopped")
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Measurement \(formatter.string(from: Date()))"
    }

    private func save() {
        guard let ir = state.lastImpulseResponse else { return }
        do {
            try store.save(ir, name: saveName)
            state.show("Saved as \(saveName)")
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

/// Presses respond immediately, on touch-down rather than on release.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.25, bounce: 0), value: configuration.isPressed)
    }
}
