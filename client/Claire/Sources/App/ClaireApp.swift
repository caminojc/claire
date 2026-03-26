import SwiftUI

@main
struct ClaireApp: App {
    @StateObject private var callManager = CallManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
        }
    }
}
