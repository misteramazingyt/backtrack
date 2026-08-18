import SwiftUI

@main
struct BacktrackApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}
