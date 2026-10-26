import SwiftUI
import WebKit
import PencilKit

// MARK: - 主视图
// 三层叠起来：
//   1. WKWebView  —— 原站点，铺满
//   2. PKCanvasView —— 精确盖住网页的作答区（用注入脚本量出来的坐标）
//   3. 工具条 —— 浮在笔迹区顶部
struct InkContentView: View {

    @StateObject private var bridge = InkBridge()

    @State private var drawing = PKDrawing()
    @State private var tool: PKTool = PKInkingTool(.pen, color: .black, width: 3)
    @State private var penColor: Color = .black
    @State private var penWidth: CGFloat = 3
    @State private var isEraser = false

    @State private var undoStack: [PKDrawing] = []
    @State private var redoStack: [PKDrawing] = []

    @State private var lastKey: String = ""
    @State private var status: String = ""
    @State private var showHUD = false

    // 网页坐标系 → SwiftUI 坐标系的换算。WKWebView 与容器同原点时就是 1:1
    private func canvasFrame(in size: CGSize) -> CGRect {
        let r = bridge.targetRect
        guard r.width > 20, r.height > 20 else { return .zero }
        // 网页 viewport 与 WKWebView 的 bounds 可能有缩放差（用户缩放）
        return r
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                InkWebPane(bridge: bridge)
                    .ignoresSafeArea()

                let frame = canvasFrame(in: geo.size)

                if frame != .zero {
                    let barH: CGFloat = 52
                    // 工具栏占顶部条带，画布从它下面开始，互不遮挡
                    let inkFrame = CGRect(x: frame.minX,
                                          y: frame.minY + barH,
                                          width: frame.width,
                                          height: max(frame.height - barH, 60))

                    // 画布底：白纸，盖住网站原本的作答区
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                        .frame(width: inkFrame.width, height: inkFrame.height)
                        .position(x: inkFrame.midX, y: inkFrame.midY)

                    InkCanvasView(drawing: $drawing, tool: $tool) { newDrawing in
                        saveIfNeeded(newDrawing)
                    }
                    .frame(width: inkFrame.width, height: inkFrame.height)
                    .position(x: inkFrame.midX, y: inkFrame.midY)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // 整块作答区的边框
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)

                    InkToolbar(tool: $tool,
                               color: $penColor,
                               width: $penWidth,
                               isEraser: $isEraser,
                               canUndo: !undoStack.isEmpty,
                               canRedo: !redoStack.isEmpty,
                               onUndo: undo,
                               onRedo: redo,
                               onClear: clear,
                               onFit: { bridge.refresh() })
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: frame.width, height: barH)
                        .position(x: frame.midX, y: frame.minY + barH / 2)
                }

                // 存盘提示：只在动作后短暂出现，不挡题目和翻页
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .position(x: frame.midX, y: frame.maxY - 18)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onChange(of: bridge.pageKey) { newKey in
                switchTo(key: newKey)
            }
            .onChange(of: bridge.targetRect) { _ in
                // 布局稳定后再量一次，防止首帧坐标偏
            }
            .onAppear {
                if !bridge.pageKey.isEmpty { switchTo(key: bridge.pageKey) }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.willResignActiveNotification)) { _ in
                flush()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didEnterBackgroundNotification)) { _ in
                flush()
            }
        }
        .preferredColorScheme(.light)
    }

    // MARK: - 存档

    private func switchTo(key: String) {
        guard !key.isEmpty, key != lastKey else { return }
        // 先把上一题的笔迹落盘
        if !lastKey.isEmpty {
            _ = InkStore.shared.save(drawing,
                                     key: lastKey,
                                     title: "第 \(bridge.questionID) 题",
                                     source: key)
        }
        let loaded = InkStore.shared.load(key)
        drawing = loaded
        undoStack.removeAll()
        redoStack.removeAll()
        lastKey = key
        flash(loaded.strokes.isEmpty ? "空白" : "已载入 \(loaded.strokes.count) 笔")
    }

    private func saveIfNeeded(_ newDrawing: PKDrawing) {
        guard !lastKey.isEmpty else { return }
        _ = InkStore.shared.save(newDrawing,
                                 key: lastKey,
                                 title: "第 \(bridge.questionID) 题",
                                 source: lastKey)
    }

    /// 退出、切后台前强制落盘，保证一笔不丢
    private func flush() {
        guard !lastKey.isEmpty else { return }
        _ = InkStore.shared.save(drawing,
                                 key: lastKey,
                                 title: "第 \(bridge.questionID) 题",
                                 source: lastKey)
        flash("已保存")
    }

    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(drawing)
        drawing = prev
        saveIfNeeded(prev)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        drawing = next
        saveIfNeeded(next)
    }

    private func clear() {
        undoStack.append(drawing)
        redoStack.removeAll()
        drawing = PKDrawing()
        saveIfNeeded(drawing)
        flash("清空")
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if status == text { status = "" }
        }
    }
}

// MARK: - WebView 包装
// 保留原工程里的导航逻辑（弹窗、外链拦截），只加注入脚本和消息桥
struct InkWebPane: UIViewRepresentable {

    let bridge: InkBridge

    func makeCoordinator() -> Nav { Nav(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"

        let ucc = WKUserContentController()
        ucc.add(bridge, name: "ink")
        let script = WKUserScript(source: inkBootstrapJS,
                                  injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: true)
        ucc.addUserScript(script)
        cfg.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = true
        web.backgroundColor = .white
        web.scrollView.contentInsetAdjustmentBehavior = .never

        bridge.webView = web

        let url = URL(string: "https://www.cxyonly.fans/math/practice")!
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Nav: NSObject, WKNavigationDelegate, WKUIDelegate {

        let bridge: InkBridge
        init(bridge: InkBridge) { self.bridge = bridge }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                webView.evaluateJavaScript("window.__inkMeasure && window.__inkMeasure();")
            }
        }
    }
}
