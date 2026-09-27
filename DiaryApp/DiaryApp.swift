import SwiftUI

@main
struct DiaryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 720, minHeight: 620)
                #endif
        }
    }
}
