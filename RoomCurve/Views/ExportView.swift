import SwiftUI
import RoomCurveKit

/// Where a correction can be sent.
struct ExportFormat: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let fileExtension: String
    let needsSampleRate: Bool
    let isText: Bool

    static let all: [ExportFormat] = [
        .init(id: "json", name: "RoomCurve JSON",
              detail: "The full correction with its conventions written down, so another tool "
                    + "cannot misread the shelf definition or the sign of a coefficient.",
              fileExtension: "json", needsSampleRate: false, isText: true),
        .init(id: "peq", name: "Parametric EQ text",
              detail: "The AutoEQ and REW dialect. Read by Equalizer APO, Wavelet, Poweramp, "
                    + "JamesDSP, Qudelix, WiiM and many others.",
              fileExtension: "txt", needsSampleRate: false, isText: true),
        .init(id: "apo", name: "Equalizer APO config",
              detail: "A config.txt for Equalizer APO or Peace on Windows.",
              fileExtension: "txt", needsSampleRate: false, isText: true),
        .init(id: "biquad", name: "Biquad coefficients",
              detail: "For miniDSP hardware. Only valid at the sample rate it is generated "
                    + "for, and the feedback coefficients are negated to match miniDSP.",
              fileExtension: "txt", needsSampleRate: true, isText: true),
        .init(id: "camilla", name: "CamillaDSP YAML",
              detail: "Filter definitions and pipeline for CamillaDSP.",
              fileExtension: "yml", needsSampleRate: false, isText: true),
        .init(id: "mpv", name: "mpv / IINA",
              detail: "An af= line for mpv.conf, or to paste into IINA's advanced settings.",
              fileExtension: "conf", needsSampleRate: false, isText: true),
        .init(id: "ir", name: "Impulse response",
              detail: "32-bit float WAV for a convolution engine — Roon, CamillaDSP, "
                    + "JamesDSP, mpv's afir.",
              fileExtension: "wav", needsSampleRate: true, isText: false),
        .init(id: "graphic", name: "Graphic EQ (fitted)",
              detail: "Describe any fixed-band equaliser — its frequencies, step size and "
                    + "range — and RoomCurve works out the settings that come closest.",
              fileExtension: "txt", needsSampleRate: false, isText: true),
        .init(id: "card", name: "Manual entry card",
              detail: "Values to type in by hand, for equalisers with no import at all.",
              fileExtension: "txt", needsSampleRate: false, isText: true)
    ]
}

struct ExportView: View {
    let filterSet: FilterSet
    var initialFormat: String?
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var format = ExportFormat.all[0]
    @State private var sampleRate = 48_000.0
    @State private var manualTarget = ManualEQTarget.parametricManual
    @State private var sharing: ShareItem?
    @State private var copied = false

    @State private var preset = GraphicEQ.tenBand
    @State private var custom = false
    @State private var frequencyText = ""
    @State private var minGain = -12.0
    @State private var maxGain = 12.0
    @State private var step = 1.0
    @State private var fitted: GraphicEQFit?
    @State private var previewLow = ResponsePlot.defaultLow
    @State private var previewHigh = ResponsePlot.defaultHigh

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.all) { Text($0.name).tag($0) }
                    }
                    Text(format.detail).font(.caption).foregroundStyle(.secondary)
                }

                if format.needsSampleRate {
                    Section("Sample rate") {
                        Picker("Rate", selection: $sampleRate) {
                            Text("44.1 kHz").tag(44_100.0)
                            Text("48 kHz").tag(48_000.0)
                            Text("96 kHz").tag(96_000.0)
                            Text("192 kHz").tag(192_000.0)
                        }
                        .pickerStyle(.segmented)
                        Text("Filters are stored as frequency, gain and Q and turned into "
                             + "coefficients here, so the export is correct for whichever rate "
                             + "your device runs at.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if format.id == "graphic" {
                    graphicEQSections
                }

                if format.id == "card" {
                    Section("Device") {
                        Picker("Device", selection: $manualTarget) {
                            ForEach(ManualEQTarget.all) { Text($0.name).tag($0) }
                        }
                        Text(manualTarget.note).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if format.isText {
                    Section("Preview") {
                        ScrollView(.horizontal) {
                            Text(text)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                }

                Section {
                    if format.isText {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy to clipboard",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                    Button {
                        share()
                    } label: {
                        Label("Save or share file…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .onAppear {
                if let initialFormat,
                   let match = ExportFormat.all.first(where: { $0.id == initialFormat }) {
                    format = match
                }
            }
            .task(id: fitKey) {
                guard format.id == "graphic" else { return }
                fitted = GraphicEQFitter.fit(targetDB: correctionDB, to: graphicEQ)
            }
            .onChange(of: format) { _, new in
                if new.id == "graphic", fitted == nil {
                    fitted = GraphicEQFitter.fit(targetDB: correctionDB, to: graphicEQ)
                }
            }
        }
    }

    // MARK: - Graphic EQ

    /// The equaliser being fitted: a preset, or whatever the user typed in.
    private var graphicEQ: GraphicEQ {
        guard custom else { return preset }
        let frequencies = frequencyText
            .split(whereSeparator: { ", \t\n".contains($0) })
            .compactMap { Double($0) }
            .filter { $0 >= 10 && $0 <= 24_000 }
        return GraphicEQ(name: "Custom (\(frequencies.count) bands)",
                         frequencies: frequencies.isEmpty ? preset.frequencies : frequencies,
                         minGainDB: minGain, maxGainDB: maxGain, stepDB: step)
    }

    private var correctionDB: [Double] { filterSet.active.combinedResponseDB() }

    /// Identity of everything the fit depends on, so it is recomputed exactly when it changes.
    private var fitKey: String {
        "\(custom)|\(preset.name)|\(frequencyText)|\(minGain)|\(maxGain)|\(step)"
    }

    private var fit: GraphicEQFit {
        fitted ?? GraphicEQFitter.fit(targetDB: correctionDB, to: graphicEQ)
    }

    /// What the equaliser will actually do, against what was asked for.
    ///
    /// A graphic equaliser with few bands cannot follow a parametric correction closely, and
    /// the numbers alone do not show where it gives up. Seeing the two curves together does.
    @ViewBuilder
    private var preview: some View {
        let result = fit
        ResponsePlot(
            series: [
                PlotSeries(id: "target", values: result.targetDB, color: .yellow,
                           lineWidth: 2.5),
                PlotSeries(id: "achieved", values: result.achievedDB, color: .cyan,
                           lineWidth: 2.5)
            ],
            kind: .magnitude, grid: .standard,
            lowFrequency: $previewLow, highFrequency: $previewHigh)
        .frame(height: 200)
        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))

        HStack(spacing: 14) {
            Label("Wanted", systemImage: "minus").foregroundStyle(.yellow)
            Label("This equaliser", systemImage: "minus").foregroundStyle(.cyan)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private var graphicEQSections: some View {
        Section("Equaliser") {
            Picker("Preset", selection: $preset) {
                ForEach(GraphicEQ.presets) { Text($0.name).tag($0) }
            }
            .disabled(custom)
            Toggle("Describe my own", isOn: $custom)
        }

        if custom {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Band frequencies, in Hz")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("60, 230, 910, 3600, 14000", text: $frequencyText, axis: .vertical)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.body.monospaced())
                        .lineLimit(2...5)
                }
                Stepper(String(format: "Lowest: %.0f dB", minGain),
                        value: $minGain, in: -40...(-1), step: 1)
                Stepper(String(format: "Highest: %+.0f dB", maxGain),
                        value: $maxGain, in: 1...40, step: 1)
                Picker("Step", selection: $step) {
                    Text("0.1 dB").tag(0.1)
                    Text("0.5 dB").tag(0.5)
                    Text("1 dB").tag(1.0)
                    Text("2 dB").tag(2.0)
                    Text("3 dB").tag(3.0)
                }
            } header: {
                Text("Your equaliser")
            } footer: {
                Text("Separate the frequencies with commas. Any number of bands works — five "
                     + "on a portable player, thirty-one on a rack unit.")
            }
        }

        Section("Preview") {
            preview
        }

        Section {
            let result = fit
            ForEach(Array(result.eq.frequencies.enumerated()), id: \.offset) { index, frequency in
                HStack {
                    Text(frequency >= 1_000
                         ? String(format: "%.4g kHz", frequency / 1_000)
                         : String(format: "%.4g Hz", frequency))
                    Spacer()
                    Text(String(format: "%+.1f dB",
                                index < result.gains.count ? result.gains[index] : 0))
                        .monospacedDigit()
                        .foregroundStyle(index < result.gains.count
                                         && abs(result.gains[index]) > 0.01 ? .primary : .secondary)
                }
                .font(.subheadline)
            }
        } header: {
            Text("Settings")
        } footer: {
            let result = fit
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Within %.1f dB on average, %.1f dB at worst.",
                            result.rmsErrorDB, result.maxErrorDB))
                if result.clipped {
                    Text("A band has reached the end of its range, so this equaliser cannot "
                         + "fully reach the correction.")
                    .foregroundStyle(.orange)
                }
                Text("Bands overlap, so these are solved together rather than read off the "
                     + "correction one frequency at a time.")
            }
        }
    }

    private var text: String {
        switch format.id {
        case "json":
            (try? filterSet.toJSON()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        case "peq": filterSet.toParametricEQText()
        case "apo": filterSet.toEqualizerAPOConfig()
        case "biquad": filterSet.toBiquadCoefficients(sampleRate: sampleRate)
        case "camilla": filterSet.toCamillaDSPYAML()
        case "mpv": filterSet.toMPVConf()
        case "card": filterSet.toManualCard(manualTarget)
        case "graphic":
            fit.card(title: filterSet.title) + "\n" + fit.graphicEQLine() + "\n"
        default: ""
        }
    }

    private func share() {
        let name = "\(filterSet.title) \(format.name).\(format.fileExtension)"
        do {
            let url: URL = if format.id == "ir" {
                try store.temporaryFile(
                    named: name,
                    contents: filterSet.impulseResponseWAV(sampleRate: sampleRate))
            } else {
                try store.temporaryFile(named: name, text: text)
            }
            sharing = ShareItem(url)
        } catch {
            // Nothing useful to say beyond the share sheet not appearing.
        }
    }
}
