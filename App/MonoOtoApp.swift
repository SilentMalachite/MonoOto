import SwiftUI

@main
struct MonoOtoApp: App {
    var body: some Scene {
        WindowGroup { PlayerView() }
            .defaultSize(width: 620, height: 580)
    }
}
