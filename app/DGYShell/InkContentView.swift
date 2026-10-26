import SwiftUI
import WebKit
import PencilKit

// MARK: - 主视图
// 三层叠起来：
//   1. WKWebView   —— 原站点，铺满
//   2. PKCanvasView —— 精确盖住网页的作答区（用注入脚本量出来的坐标）
//   3. 工具条      —— 浮在笔迹区顶部，落笔即收起，停笔自动浮回
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

    // 工具栏自动隐藏
    @State private var barVisible = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var writing = false
    /// 用户手动收起后锁住，落笔/抬笔都不再自动弹出，只有点把手才回来
    @State private var barPinned = false

    private func canvasFrame(in size: CGSize) -> CGRect {
        let r = bridge.targetRect
        guard r.width > 20, r.height > 20 else { return .zero }
        return r
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                InkWebPane(bridge: bridge)
                    .ignoresSafeArea()

                let frame = canvasFrame(in: geo.size)

                if frame != .zero {
                    // 画布铺满整个作答区，工具栏只做浮层，不再占高度
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    InkCanvasView(drawing: $drawing,
                                  tool: $tool,
                                  onDrawingChanged: { newDrawing in
                                      saveIfNeeded(newDrawing)
                                  },
                                  onPinchToggleTool: {
                                      toggleToolByPinch()
                                  },
                                  onPinchToggleToolIfNeeded: { eraser in
                                      syncToolFromPencil(eraser: eraser)
                                  },
                                  onStrokeBegan: {
                                      onStrokeBegan()
                                  },
                                  onStrokeEnded: {
                                      scheduleBarShow()
                                  })
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // 边框
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)

                    // 浮层工具栏
                    if barVisible {
                        InkToolbar(tool: $tool,
                                   color: $penColor,
                                   width: $penWidth,
                                   isEraser: $isEraser,
                                   canUndo: !undoStack.isEmpty,
                                   canRedo: !redoStack.isEmpty,
                                   onUndo: undo,
                                   onRedo: redo,
                                   onClear: clear,
                                   onHide: { hideBar() })
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .frame(width: frame.width, height: 52)
                            .position(x: frame.midX, y: frame.minY + 26)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        // 收起后只留一个小把手，点一下立刻展开
                        Button {
                            showBar()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 18)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .position(x: frame.midX, y: frame.minY + 10)
                    }
                }

                // 存盘提示
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
            .animation(.easeInOut(duration: 0.18), value: barVisible)
            .onChange(of: bridge.pageKey) { newKey in
                switchTo(key: newKey)
                barPinned = false
                showBar()
            }
            .onAppear {
                if !bridge.pageKey.isEmpty { switchTo(key: bridge.pageKey) }
                scheduleBarShow()
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

    // MARK: - 工具栏收放

    /// 落笔：立刻收起，把纸让出来
    private func onStrokeBegan() {
        writing = true
        hideTask?.cancel()
        // 手动收起状态下本来就看不见，不用动
        if barVisible && !barPinned {
            barVisible = false
        }
    }

    /// 抬笔：等一会儿再浮回来，别打断思路。
    /// 手动收起的状态下不自动弹。
    private func scheduleBarShow() {
        writing = false
        hideTask?.cancel()
        guard !barPinned else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !writing, !barPinned else { return }
            barVisible = true
        }
    }

    /// 点把手 / 用工具后主动展开，解除手动锁
    private func showBar() {
        hideTask?.cancel()
        barPinned = false
        barVisible = true
        scheduleBarShow()
    }

    /// 用户主动收起：锁住，不再自动浮回，等他点把手
    private func hideBar() {
        hideTask?.cancel()
        writing = false
        barPinned = true
        barVisible = false
    }

    // MARK: - 工具同步

    /// 系统轻捏已经改了 canvas.tool，这里把 SwiftUI 的 tool 也对齐，
    /// 否则下一帧 updateUIView 会覆盖回去
    private func syncToolFromPencil(eraser: Bool) {
        if eraser {
            if !isEraser {
                isEraser = true
                if #available(iOS 16.4, *) {
                    tool = PKEraserTool(.bitmap, width: 20.0 as CGFloat)
                } else {
                    tool = PKEraserTool(.bitmap)
                }
                flash("橡皮")
            }
        } else {
            if isEraser {
                isEraser = false
                tool = PKInkingTool(.pen, color: UIColor(penColor), width: penWidth)
                flash("笔")
            }
        }
    }

    /// 双指捏合：笔 ⇄ 橡皮
    private func toggleToolByPinch() {
        if isEraser {
            isEraser = false
            tool = PKInkingTool(.pen, color: UIColor(penColor), width: penWidth)
        } else {
            isEraser = true
            if #available(iOS 16.4, *) {
                tool = PKEraserTool(.bitmap, width: 20.0 as CGFloat)
            } else {
                tool = PKEraserTool(.bitmap)
            }
        }
        flash(isEraser ? "橡皮" : "笔")
        showBar()
    }

    // MARK: - 存档

    private func switchTo(key: String) {
        guard !key.isEmpty, key != lastKey else { return }
        if !lastKey.isEmpty {
            _ = InkStore.shared.save(drawing,
                                     key: lastKey,
                                     title: "第 \(bridge.questionID) 题",
                                     source: lastKey)
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
        showBar()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        drawing = next
        saveIfNeeded(next)
        showBar()
    }

    private func clear() {
        undoStack.append(drawing)
        redoStack.removeAll()
        drawing = PKDrawing()
        saveIfNeeded(drawing)
        flash("清空")
        showBar()
    }

    private func flash(_ text: String) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if status == text { status = "" }
        }
    }
}

// MARK: - WebView 包装
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
