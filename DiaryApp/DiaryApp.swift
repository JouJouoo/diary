import SwiftUI

@main
struct DiaryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(iOS) && targetEnvironment(simulator)
                .environment(\.font, .appSystem(.body))
                #endif
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 620)
                #endif
        }
    }
}
