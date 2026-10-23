import SwiftUI

@main
struct DGYShellApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // 全屏铺满：整个窗口范围内渲染，含刘海区与底部小白条区
                .ignoresSafeArea(.all, edges: .all)
                .preferredColorScheme(.light)
        }
    }
}
