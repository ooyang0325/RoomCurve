import SwiftUI
import RoomCurveKit

struct RealTimeView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioEngine

    @State private var low = 20.0
    @State private var high = 20_000.0
    @State private var running = false
    @State private var response: FrequencyResponse?
    @State private var analyser: RealTimeAnalyser?
    @State private var noise: PinkNoiseStimulus?
    @State private var showPlotSetup = false
    @State private var refresh: Task<Void, Never>?
    @State private var saveName = ""
    @State private var showSave = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isShort: Bool { verticalSizeClass == .compact }

    var body: some View {
        Group {
            if isShort {
                plot
                    .padding(.trailing, 74)
                    .overlay(alignment: .trailing) { controls.padding(.trailing, 6) }
            } else {
                VStack(spacing: 0) {
                    plot
                    toolbar
                }
            }
        }
        .navigationTitle("Real Time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RoutePickerButton().frame(width: 40, height: 40)
            }
        }
        .sheet(isPresented: $showPlotSetup) { PlotSetupView() }
        .alert("Save measurement", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { save() }
        } message: {
            Text("Saves the current response so it can be equalised or compared later.")
        }
        .onDisappear { stop() }
    }

    private var plot: some View {
        ResponsePlot(series: series, kind: .magnitude, grid: state.grid,
                     lowFrequency: $low, highFrequency: $high)
        .padding(.horizontal, 8)
        .overlay(alignment: .top) {
            if response == nil {
                ContentUnavailableView(
                    "Not measuring",
                    systemImage: "waveform",
                    description: Text("Pink noise plays continuously so you can watch the "
                                      + "response change as you adjust something."))
                .allowsHitTesting(false)
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $state.realTimeMode) {
                ForEach(RealTimeAnalyser.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .onChange(of: state.realTimeMode) { _, mode in analyser?.mode = mode }

            Text(state.realTimeMode == .live
                 ? "A few seconds of running average — move a control and watch it respond."
                 : "Averages indefinitely. Walk the phone slowly around the listening area to "
                 + "capture the whole space rather than one seat.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            controls
        }
        .padding(.top, 4)
    }

    private var controlLayout: AnyLayout {
        isShort ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 18))
    }

    private var controls: some View {
        GlassGroup {
                controlLayout {
                    Button { showPlotSetup = true } label: {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.body).frame(width: 30, height: 30)
                    }
                    .secondaryAction()

                    Button {
                        running ? stop() : start()
                    } label: {
                        Image(systemName: running ? "stop.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .tint(running ? .red : .accentColor)
                    .prominentAction()
                    .accessibilityLabel(running ? "Stop" : "Start")

                    Button {
                        saveName = defaultName()
                        showSave = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.body).frame(width: 30, height: 30)
                    }
                    .secondaryAction()
                    .disabled(response == nil)
                    .accessibilityLabel("Save measurement")

                    Button {
                        analyser?.reset()
                        response = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body).frame(width: 30, height: 30)
                    }
                    .secondaryAction()
                    .disabled(response == nil)
                }
                .floatingBar()
        }
        .padding(.bottom, 6)
    }

    private var series: [PlotSeries] {
        var result: [PlotSeries] = [
            PlotSeries(id: "target", values: state.fittedTarget(from: store),
                       color: .yellow, lineWidth: 2, band: 3)
        ]
        if let comparison = state.comparisonMeasurement, let ir = try? comparison.load() {
            let saved = Analyser.response(of: ir).smoothed(state.smoothing)
            result.append(PlotSeries(id: "saved", values: saved.magnitudeDB,
                                     color: .gray, lineWidth: 1.5))
        }
        if let response {
            result.append(PlotSeries(id: "live",
                                     values: response.smoothed(state.smoothing).magnitudeDB,
                                     color: .green, lineWidth: 2.5))
        }
        return result
    }

    private func start() {
        let stimulus = noise ?? PinkNoiseGenerator.make(duration: 30,
                                                        sampleRate: audio.sampleRate)
        noise = stimulus
        let engine = RealTimeAnalyser(stimulus: stimulus, mode: state.realTimeMode)
        analyser = engine

        do {
            try audio.startRealTime(noise: stimulus, channel: state.realTimeChannel) { samples in
                engine.process(samples)
            }
        } catch {
            state.errorMessage = error.localizedDescription
            return
        }
        running = true

        // Redraw on a timer rather than per buffer; the plot does not need to update faster
        // than the eye can follow, and the capture thread should not be driving SwiftUI.
        refresh = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let calibrated = engine.response().map { state.calibrated($0, store: store) }
                await MainActor.run { response = calibrated }
            }
        }
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Real Time \(formatter.string(from: Date()))"
    }

    /// Save a pink-noise measurement as an impulse response.
    ///
    /// Pink noise only ever recovers magnitude, but everything downstream — the store, the
    /// equaliser, the exporters — already speaks impulse responses. Rendering the magnitude
    /// into a minimum-phase one means real-time measurements can generate room correction
    /// through exactly the same path as swept-sine ones, with nothing else changed.
    private func save() {
        guard let response else { return }
        do {
            try store.save(response.asImpulseResponse(sampleRate: audio.sampleRate),
                           name: saveName)
            state.show("Saved \(saveName) — equalise it from the Equalize tool")
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func stop() {
        refresh?.cancel()
        refresh = nil
        audio.stop()
        running = false
    }
}
