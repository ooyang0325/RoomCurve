import SwiftUI
import AVKit
import RoomCurveKit

struct MenuView: View {
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tool("Sweep", "waveform.path", "Measure with a logarithmic sine sweep") {
                        SweepView()
                    }
                    tool("Real Time", "waveform", "Measure continuously with pink noise") {
                        RealTimeView()
                    }
                    tool("Equalize", "slider.horizontal.3",
                         "Generate room correction from a saved measurement") {
                        EqualizeView()
                    }
                    tool("Curve Editor", "point.topleft.down.curvedto.point.bottomright.up",
                         "Create and edit target curves") {
                        CurveEditorView()
                    }
                    tool("Measurements", "folder", "Saved measurements and calibrations") {
                        MeasurementsView()
                    }
                }

                Section("Audio") {
                    LabeledContent("Output", value: audio.routeDescription)
                    LabeledContent("Input", value: audio.inputDescription)
                    if audio.isCarPlayInput {
                        Label("CarPlay uses the car's own microphone, not the phone's. "
                              + "Connect by Bluetooth or a cable instead.",
                              systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                    RoutePickerButton()
                        .frame(height: 44)
                }

                Section {
                    NavigationLink { HelpView() } label: {
                        Label("How to measure", systemImage: "questionmark.circle")
                    }
                } footer: {
                    Text("RoomCurve is open source. Measurements, curves and filters are "
                         + "stored as ordinary files you can open in the Files app.")
                }
            }
            .navigationTitle("RoomCurve")
            .alert("Measurement problem", isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } })) {
                Button("OK", role: .cancel) { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
        }
    }

    private func tool<Destination: View>(_ title: String, _ icon: String, _ subtitle: String,
                                         @ViewBuilder destination: @escaping () -> Destination)
        -> some View {
        NavigationLink {
            destination()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// The system AirPlay and Bluetooth picker.
///
/// Uses `AVRoutePickerView` rather than a custom list because it is the only way to reach the
/// low-latency route the app needs — the buffered AirPlay that music apps use is not available
/// to anything that records at the same time as it plays.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct HelpView: View {
    var body: some View {
        List {
            Section("Getting a good measurement") {
                step("Connect", "Pick an output with the AirPlay button, or plug in a cable. "
                     + "Wired is the most reliable.")
                step("Set the level", "Start quiet, measure, then raise the volume until the "
                     + "sweep is clearly audible at a normal listening level.")
                step("Aim the phone", "Point the microphone at the speaker. The phone's own "
                     + "body shadows the microphone by several dB above 3 kHz.")
                step("Uncover the microphone", "Keep your hand off the bottom edge, and take "
                     + "the case off if the measurement looks wrong.")
                step("Average several positions", "Measure around the listening area and let "
                     + "the app average. One position alone is full of narrow nulls that only "
                     + "exist at that exact spot.")
            }

            Section("Before you equalise") {
                Text("Match speaker levels first, then crossovers, then time alignment. "
                     + "Equalisation is the last step, not the first.")
                Text("Correct peaks, not narrow dips. A deep narrow null comes from the room "
                     + "cancelling itself at that one spot; boosting it just spends amplifier "
                     + "power making every other seat worse.")
                Text("Below roughly 300 Hz the room is in charge, above it the speaker is. "
                     + "Most of the benefit is down low.")
            }

            Section("Microphone") {
                Text("The built-in microphone is good enough for tuning. It is flat through "
                     + "the midrange but rolls off in the bass, so pick a calibration in "
                     + "Measurements › Calibration if one exists for your device.")
                Text("An external calibrated microphone (UMIK-1, iMM-6) is better still, and "
                     + "you can use one to derive a calibration for the built-in microphone.")
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
