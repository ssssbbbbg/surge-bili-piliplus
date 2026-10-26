import SwiftUI

@main
struct DGYShellApp: App {
    var body: some Scene {
        WindowGroup {
            InkContentView()
                .ignoresSafeArea(.all, edges: .all)
                .preferredColorScheme(.light)
        }
    }
}
