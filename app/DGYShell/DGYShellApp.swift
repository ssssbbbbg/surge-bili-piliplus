import SwiftUI

@main
struct DGYShellApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea(.all, edges: .bottom)
                .preferredColorScheme(.light)
        }
    }
}
