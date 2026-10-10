import SwiftUI

@main
struct SoftboxApp: App {
    @StateObject private var light = LightController.shared
    @StateObject private var bridge = BridgeController()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(light)
                .environmentObject(bridge)
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}
