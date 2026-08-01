import SwiftUI
import UniformTypeIdentifiers
import RoomCurveKit

struct MeasurementsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState

    @State private var sharing: ShareItem?
    @State private var importingCurve = false
    @State private var importingCalibration = false
    @State private var deriving = false

    var body: some View {
        List {
            Section("Measurements") {
                if store.measurements.isEmpty {
                    Text("Nothing saved yet.").foregroundStyle(.secondary)
                }
                ForEach(store.measurements) { measurement in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(measurement.name)
                            Text(measurement.modified, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            sharing = ShareItem(measurement.url)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { indexes in
                    indexes.map { store.measurements[$0] }.forEach(store.delete)
                }
            }

            Section {
                ForEach(store.targetCurves) { curve in
                    HStack {
                        Text(curve.name)
                        if curve.isBuiltIn {
                            Text("built in").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexes in
                    indexes.map { store.targetCurves[$0] }.forEach { store.delete(curve: $0) }
                }
                Button {
                    importingCurve = true
                } label: {
                    Label("Import curve…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Target curves")
            } footer: {
                Text("Any two-column frequency and gain text file works — the same format REW "
                     + "and other tools use, so published curves can be dropped straight in.")
            }

            Section {
                ForEach(store.calibrations) { calibration in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calibration.name)
                        if calibration.isEstimate {
                            Label("Estimate, not measured", systemImage: "exclamationmark.triangle")
                                .font(.caption2).foregroundStyle(.orange)
                        } else if let source = calibration.source {
                            Text(source).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    importingCalibration = true
                } label: {
                    Label("Import calibration…", systemImage: "square.and.arrow.down")
                }
                Button {
                    deriving = true
                } label: {
                    Label("Derive from two measurements…", systemImage: "wand.and.stars")
                }
                .disabled(store.measurements.count < 2)
            } header: {
                Text("Microphone calibration")
            } footer: {
                Text("Measure a speaker with a calibrated microphone, then again with the "
                     + "built-in one from the same spot. The difference between them is the "
                     + "built-in microphone, and that file is worth sharing.")
            }
        }
        .navigationTitle("Measurements")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $deriving) { DeriveCalibrationView() }
        .fileImporter(isPresented: $importingCurve,
                      allowedContentTypes: [.plainText, .text, .data]) { result in
            handleImport(result, asCalibration: false)
        }
        .fileImporter(isPresented: $importingCalibration,
                      allowedContentTypes: [.plainText, .text, .data]) { result in
            handleImport(result, asCalibration: true)
        }
    }

    private func handleImport(_ result: Result<URL, Error>, asCalibration: Bool) {
        do {
            let url = try result.get()
            let name = try store.importCurve(from: url, asCalibration: asCalibration)
            state.show("Imported \(name)")
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

/// Build a calibration for one microphone by comparing two measurements of the same speaker.
struct DeriveCalibrationView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var reference: SavedMeasurement?
    @State private var underTest: SavedMeasurement?
    @State private var name = ""
    @State private var preview: MicrophoneCalibration?
    @State private var low = 20.0
    @State private var high = 20_000.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    picker("Reference microphone", selection: $reference)
                    picker("Microphone to calibrate", selection: $underTest)
                    TextField("Name", text: $name)
                } footer: {
                    Text("Both measurements must be of the same speaker from the same position. "
                         + "Everything that differs between them is attributed to the second "
                         + "microphone.")
                }

                if let preview {
                    Section("Result") {
                        ResponsePlot(
                            series: [PlotSeries(id: "cal",
                                                values: preview.sampled(on: state.grid),
                                                color: .purple, lineWidth: 2)],
                            kind: .magnitude, grid: state.grid,
                            lowFrequency: $low, highFrequency: $high)
                        .frame(height: 200)
                        Text("Negative means the microphone reads low there, so measurements "
                             + "get raised by that amount.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Derive Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(preview == nil || name.isEmpty)
                }
            }
            .onChange(of: reference) { _, _ in compute() }
            .onChange(of: underTest) { _, _ in compute() }
        }
    }

    private func picker(_ label: String,
                        selection: Binding<SavedMeasurement?>) -> some View {
        Picker(label, selection: selection) {
            Text("Choose…").tag(SavedMeasurement?.none)
            ForEach(store.measurements) { Text($0.name).tag(SavedMeasurement?.some($0)) }
        }
    }

    private func compute() {
        guard let reference, let underTest,
              let referenceIR = try? reference.load(),
              let testIR = try? underTest.load() else {
            preview = nil
            return
        }
        if name.isEmpty { name = "\(UIDevice.current.model) microphone" }
        preview = MicrophoneCalibration.derive(
            reference: Analyser.response(of: referenceIR),
            microphone: Analyser.response(of: testIR),
            name: name)
    }

    private func save() {
        guard var calibration = preview else { return }
        calibration.name = name
        calibration.notes = "Derived from \(reference?.name ?? "?") and \(underTest?.name ?? "?")."
        do {
            try store.save(calibration)
            state.show("Saved \(name)")
            dismiss()
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}
