#if DEBUG
import Foundation
import SwiftUI
import RoomCurveKit

/// Launch straight into a screen with synthetic data, so screens can be inspected from the
/// command line without tapping through the app:
///
///     xcrun simctl launch <device> studio.ooyang.RoomCurve -demoScreen sweep
///
/// Debug builds only. Present because a room measurement needs a room, and the plot is the
/// part of this app most worth looking at with your own eyes.
enum DemoLaunch {

    static var requestedScreen: String? {
        UserDefaults.standard.string(forKey: "demoScreen")
    }

    /// The menu with one screen already pushed on top of it, so the back button and the edge
    /// swipe work the same way they do in normal use.
    struct Root: View {
        let screen: String

        init(screen: String) { self.screen = screen }

        @State private var path: [String] = []

        var body: some View {
            NavigationStack(path: $path) {
                MenuView()
                    .navigationDestination(for: String.self) { destination in
                        switch destination {
                        case "sweep": SweepView()
                        case "realtime": RealTimeView()
                        case "equalize": EqualizeView()
                        case "curve": CurveEditorView()
                        case "measurements": MeasurementsView()

                        default: EmptyView()
                        }
                    }
            }
            // ExportView carries its own navigation stack because it is designed as a sheet;
            // pushing it into another stack is not a valid composition.
            .sheet(isPresented: .constant(screen == "export")) { DemoExport() }
            .onAppear { if path.isEmpty && screen != "export" { path = [screen] } }
        }
    }

    /// The export sheet on its own, with a correction to work from, so its screens can be
    /// inspected without tapping through the app.
    struct DemoExport: View {
        @EnvironmentObject private var state: AppState

        var body: some View {
            let room = [
                Biquad(type: .peaking, frequency: 55, gainDB: -7, q: 3),
                Biquad(type: .peaking, frequency: 140, gainDB: 5, q: 2.5),
                Biquad(type: .peaking, frequency: 480, gainDB: -4, q: 2),
                Biquad(type: .highShelf, frequency: 6_000, gainDB: 3, q: 0.707)
            ]
            ExportView(filterSet: FilterSet(title: "Demo Room", preampDB: -5, filters: room),
                       initialFormat: "graphic")
        }
    }

    /// Save one measurement too, so the Equalize tool has something to work from.
    static func seedStore(_ store: Store, state: AppState) {
        guard store.measurements.isEmpty, let first = state.captures.first else { return }
        try? store.save(first.asImpulseResponse(), name: "Demo Room")
    }

    /// A synthetic room: a couple of modal peaks, a suckout, and a low-frequency rolloff.
    static func seed(_ state: AppState) {
        let grid = state.grid
        let room = [
            Biquad(type: .peaking, frequency: 42, gainDB: 9, q: 5),
            Biquad(type: .peaking, frequency: 68, gainDB: -8, q: 4),
            Biquad(type: .peaking, frequency: 125, gainDB: 6, q: 3),
            Biquad(type: .peaking, frequency: 240, gainDB: -4, q: 2.5),
            Biquad(type: .peaking, frequency: 2_400, gainDB: 3, q: 1.5),
            Biquad(type: .highShelf, frequency: 7_000, gainDB: -5, q: 0.707),
            Biquad(type: .lowShelf, frequency: 45, gainDB: -14, q: 0.9)
        ]

        for seed in 0..<4 {
            var rng = SystemRandomNumberGenerator()
            var magnitude = room.combinedResponseDB(on: grid).map { $0 + 75 }
            // Each position gets its own narrow nulls, the way real seats do.
            let null = Biquad(type: .peaking, frequency: 80 + Double(seed) * 22,
                              gainDB: -14, q: 11).responseDB(on: grid)
            var snr = [Double](repeating: 45, count: grid.count)
            for i in 0..<grid.count {
                magnitude[i] += null[i] + Double.random(in: -0.6...0.6, using: &rng)
                // Nothing usable below what the speaker can actually produce.
                if grid.frequencies[i] < 32 { snr[i] = 2 }
            }
            state.addCapture(FrequencyResponse(
                grid: grid, magnitudeDB: magnitude,
                phaseDegrees: grid.frequencies.map {
                    let wrapped = (-$0 / 40).truncatingRemainder(dividingBy: 360)
                    return wrapped > 180 ? wrapped - 360 : (wrapped < -180 ? wrapped + 360 : wrapped)
                },
                groupDelayMS: grid.frequencies.map { 8 * exp(-$0 / 400) + 1.5 },
                snrDB: snr))
        }
    }
}
#endif
