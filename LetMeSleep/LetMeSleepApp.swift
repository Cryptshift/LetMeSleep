import SwiftUI

@main
struct LetMeSleepApp: App {
    @State private var monitor = SoundMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
        }
    }
}
