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
        .init(id: "card", name: "Manual entry card",
              detail: "Values to type in by hand, for equalisers with no import at all.",
              fileExtension: "txt", needsSampleRate: false, isText: true)
    ]
}

struct ExportView: View {
    let filterSet: FilterSet
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var format = ExportFormat.all[0]
    @State private var sampleRate = 48_000.0
    @State private var manualTarget = ManualEQTarget.parametricManual
    @State private var sharing: ShareItem?
    @State private var copied = false

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
