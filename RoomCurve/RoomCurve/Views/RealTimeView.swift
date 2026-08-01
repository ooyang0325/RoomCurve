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

    var body: some View {
        VStack(spacing: 0) {
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
            toolbar
        }
        .navigationTitle("Real Time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RoutePickerButton().frame(width: 40, height: 40)
            }
        }
        .sheet(isPresented: $showPlotSetup) { PlotSetupView() }
        .onDisappear { stop() }
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

            HStack(spacing: 22) {
                Button {
                    showPlotSetup = true
                } label: {
                    Image(systemName: "chart.xyaxis.line").font(.title3)
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    running ? stop() : start()
                } label: {
                    ZStack {
                        Circle()
                            .fill(running ? Color.red : Color.accentColor)
                            .frame(width: 62, height: 62)
                        Image(systemName: running ? "stop.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    analyser?.reset()
                    response = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.title3)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(response == nil)
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 10)
        .background(.bar)
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

    private func stop() {
        refresh?.cancel()
        refresh = nil
        audio.stop()
        running = false
    }
}
