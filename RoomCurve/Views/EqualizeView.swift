import SwiftUI
import RoomCurveKit

struct EqualizeView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState

    @State private var low = 20.0
    @State private var high = 20_000.0
    @State private var source: SavedMeasurement?
    @State private var measured: FrequencyResponse?
    @State private var correction: Correction?
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var showExport = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isShort: Bool { verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            if measured == nil {
                ContentUnavailableView {
                    Label("No measurement selected", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Correction is generated from a saved measurement. Average several "
                         + "positions in the listening area first — correcting a single "
                         + "position bakes in nulls that only exist at that spot.")
                } actions: {
                    Menu("Choose measurement") { measurementMenu }
                }
                .frame(maxHeight: .infinity)
            } else if isShort {
                // Landscape gives the plot the whole screen; the readouts and controls float.
                ResponsePlot(series: series, kind: .magnitude, grid: state.grid,
                             lowFrequency: $low, highFrequency: $high)
                .padding(.horizontal, 8)
                .padding(.trailing, 92)
                .overlay(alignment: .top) {
                    summary.padding(.horizontal, 40)
                }
                .overlay(alignment: .trailing) { toolbar }
            } else {
                ResponsePlot(series: series, kind: .magnitude, grid: state.grid,
                             lowFrequency: $low, highFrequency: $high)
                .padding(.horizontal, 8)
                summary
                toolbar
            }
        }
        .navigationTitle("Equalize")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    measurementMenu
                } label: {
                    Image(systemName: "folder")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            EqualizeSetupView().onDisappear { recompute() }
        }
        .sheet(isPresented: $showFilters) {
            FilterDetailView(correction: correction)
        }
        .sheet(isPresented: $showExport) {
            if let correction, let source {
                ExportView(filterSet: FilterSet(
                    title: source.name,
                    preampDB: correction.preampDB,
                    filters: correction.filters,
                    provenance: Provenance(
                        microphone: state.applyCalibration ? state.calibrationName : "Uncalibrated",
                        targetCurve: state.selectedTargetName)))
            }
        }
        .onAppear { if source == nil { source = store.measurements.first; load() } }
    }

    private var measurementMenu: some View {
        ForEach(store.measurements) { measurement in
            Button(measurement.name) {
                source = measurement
                load()
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            stat("Filters", "\(correction?.filters.count ?? 0)")
            stat("Max boost", String(format: "%.1f dB", correction?.maxBoostDB ?? 0),
                 warn: (correction?.maxBoostDB ?? 0) > state.eqSettings.maxGainDB + 0.01)
            stat("Preamp", String(format: "%.1f dB", correction?.preampDB ?? 0))
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func stat(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? .red : .primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlLayout: AnyLayout {
        isShort ? AnyLayout(VStackLayout(spacing: 16))
                : AnyLayout(HStackLayout(spacing: 18))
    }

    private var toolbar: some View {
        GlassGroup {
            controlLayout {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.body).frame(width: 30, height: 30)
                }
                .secondaryAction()

                Button { showFilters = true } label: {
                    Image(systemName: "list.number").font(.body).frame(width: 30, height: 30)
                }
                .secondaryAction()
                .disabled(correction?.filters.isEmpty ?? true)

                Button { showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(height: 30)
                        .padding(.horizontal, 6)
                }
                .prominentAction()
                .disabled(correction?.filters.isEmpty ?? true)
            }
            .floatingBar()
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    private var series: [PlotSeries] {
        guard let measured else { return [] }
        var result: [PlotSeries] = [
            PlotSeries(id: "target", values: fittedTarget, color: .yellow, lineWidth: 2, band: 3),
            PlotSeries(id: "measured", values: measured.magnitudeDB, color: .gray,
                       lineWidth: 1.5, blanked: state.blanked(for: measured))
        ]
        if let correction {
            result.append(PlotSeries(id: "filter", values: correction.filterResponseDB,
                                     color: .purple, lineWidth: 2))
            result.append(PlotSeries(id: "predicted", values: correction.predictedDB,
                                     color: .cyan, lineWidth: 2.5,
                                     blanked: state.blanked(for: measured)))
        }
        return result
    }

    private var fittedTarget: [Double] {
        guard let measured else { return [] }
        let target = state.targetCurve(from: store).sampled(on: state.grid)
        switch state.curveFit {
        case .manual(let level):
            return target.map { $0 + level }
        case .automatic:
            let offset = TargetCurve.fitOffset(
                target: target, measured: measured.magnitudeDB,
                blanked: state.blanked(for: measured),
                range: state.grid.indices(from: 20, to: 20_000))
            return target.map { $0 + offset }
        }
    }

    private func load() {
        guard let source, let ir = try? source.load() else {
            measured = nil
            return
        }
        measured = state.calibrated(Analyser.response(of: ir).smoothed(state.smoothing),
                                    store: store)
        recompute()
    }

    private func recompute() {
        guard let measured else { return }
        correction = AutoEQ.correct(measuredDB: measured.magnitudeDB,
                                    targetDB: fittedTarget,
                                    snrDB: measured.snrDB,
                                    settings: state.eqSettings,
                                    grid: state.grid)
    }
}

struct EqualizeSetupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Filter type") {
                    Picker("Type", selection: $state.eqSettings.kind) {
                        ForEach(CorrectionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(state.eqSettings.kind == .parametric
                         ? "A handful of biquad filters, for a parametric equaliser."
                         : "A single impulse response, for a convolution engine. Higher "
                         + "fidelity, at the cost of about 250 ms of delay.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Range") {
                    FrequencyField(title: "From", value: $state.eqSettings.minFrequency,
                                   range: 20...2_000)
                        .onChange(of: state.eqSettings.minFrequency) { _, _ in keepRangeOrdered() }
                    FrequencyField(title: "To", value: $state.eqSettings.maxFrequency,
                                   range: 40...20_000)
                        .onChange(of: state.eqSettings.maxFrequency) { _, _ in keepRangeOrdered() }
                    Text("Most of the benefit is below a few hundred hertz, where the room "
                         + "rather than the speaker is in charge. Correcting the top end "
                         + "spends filters on things that are barely audible.")
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section("Limits") {
                    LabeledContent("Max gain") {
                        Text(String(format: "%.0f dB", state.eqSettings.maxGainDB))
                    }
                    Slider(value: $state.eqSettings.maxGainDB, in: 1...15, step: 1)
                        .onChange(of: state.eqSettings.maxGainDB) { _, value in
                            state.eqSettings.maxTotalBoostDB = value
                        }
                    Toggle("Only cuts", isOn: $state.eqSettings.allowOnlyCuts)
                    Stepper("Max filters: \(state.eqSettings.maxFilters)",
                            value: $state.eqSettings.maxFilters, in: 1...31)
                    LabeledContent("Max Q") {
                        Text(String(format: "%.0f", state.eqSettings.maxQ))
                    }
                    Slider(value: $state.eqSettings.maxQ, in: 1...20, step: 1)
                    Toggle("Allow shelf filters", isOn: $state.eqSettings.allowShelfFilters)
                    Text("Boost is capped for the whole filter chain, not just each filter, "
                         + "so several filters cannot stack up into a large boost. Boosts that "
                         + "would ring are refused outright — that is what stops the app "
                         + "trying to fill in a narrow null.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Equalize Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension EqualizeSetupView {
    /// Keep the range the right way round, whichever end was just moved.
    func keepRangeOrdered() {
        let lowest = state.eqSettings.minFrequency
        if state.eqSettings.maxFrequency < lowest * 1.2 {
            state.eqSettings.maxFrequency = Swift.min(lowest * 1.2, 20_000)
        }
    }
}

struct FilterDetailView: View {
    let correction: Correction?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array((correction?.filters ?? []).enumerated()), id: \.offset) {
                        index, filter in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                            Text(filter.type.rawValue)
                                .font(.caption.weight(.semibold))
                                .frame(width: 38, alignment: .leading)
                            Text(filter.frequency >= 1000
                                 ? String(format: "%.2f kHz", filter.frequency / 1000)
                                 : String(format: "%.0f Hz", filter.frequency))
                            .frame(width: 78, alignment: .trailing)
                            Text(String(format: "%+.1f dB", filter.gainDB))
                                .frame(width: 70, alignment: .trailing)
                                .foregroundStyle(filter.gainDB > 0 ? .orange : .primary)
                            Text(String(format: "Q %.2f", filter.q))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(.footnote.monospacedDigit())
                    }
                } footer: {
                    Text("PK is a peaking filter, LSC and HSC are shelves specified at the "
                         + "middle of their transition rather than the corner. If your "
                         + "equaliser asks for a shelf corner frequency instead, these numbers "
                         + "need converting.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
