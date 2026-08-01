import SwiftUI

@main
struct RoomCurveApp: App {
    @StateObject private var store = Store()
    @StateObject private var state = AppState()
    @StateObject private var audio = AudioEngine()

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(store)
                .environmentObject(state)
                .environmentObject(audio)
                .task {
                    try? await audio.requestPermission()
                    try? audio.configureSession()
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if let screen = DemoLaunch.requestedScreen {
            NavigationStack {
                switch screen {
                case "sweep": SweepView()
                case "realtime": RealTimeView()
                case "equalize": EqualizeView()
                case "curve": CurveEditorView()
                case "measurements": MeasurementsView()
                default: MenuView()
                }
            }
            .onAppear { if state.captures.isEmpty { DemoLaunch.seed(state) } }
        } else {
            MenuView()
        }
        #else
        MenuView()
        #endif
    }
}
