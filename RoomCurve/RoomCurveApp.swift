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
            // Push the screen onto a real stack rooted at the menu, so Back behaves exactly
            // as it does when you navigate there yourself.
            DemoLaunch.Root(screen: screen)
                                .onAppear {
                    if state.captures.isEmpty { DemoLaunch.seed(state) }
                    DemoLaunch.seedStore(store, state: state)
                }
        } else {
            MenuView()
        }
        #else
        MenuView()
        #endif
    }
}
