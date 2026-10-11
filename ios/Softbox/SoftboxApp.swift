import SwiftUI

@main
struct SoftboxApp: App {
    @StateObject private var light = LightController.shared
    @StateObject private var bridge = BridgeController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(light)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
                .onChange(of: phase) { _, p in if p == .active { light.wake() } }
        }
    }
}
