import SwiftUI

@main
struct ClaireApp: App {
    @StateObject private var callManager = CallManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(callManager)
                #if os(macOS)
                .onAppear {
                    // Set dock icon from bundle
                    if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
                       let icon = NSImage(contentsOfFile: iconPath) {
                        NSApp.applicationIconImage = icon
                    }
                }
                #endif
        }
    }
}
