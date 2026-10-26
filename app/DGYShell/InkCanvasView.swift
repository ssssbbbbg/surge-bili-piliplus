import SwiftUI
import PencilKit
import QuartzCore

// MARK: - PencilKit 画布
// 覆盖在网页作答区上方。原生笔迹：压感、倾斜、平滑、防误触都是系统级。
struct InkCanvasView: UIViewRepresentable {

    @Binding var drawing: PKDrawing
    @Binding var tool: PKTool
    var onDrawingChanged: (PKDrawing) -> Void
    /// 双指捏合：在笔和橡皮之间来回切（照无边记的手感）
    var onPinchToggleTool: () -> Void = {}
    /// 系统轻捏改了工具后，把状态同步回 SwiftUI（只更新高亮，不再改 canvas）
    var onPinchToggleToolIfNeeded: (Bool) -> Void = { _ in }
    /// 落笔/抬笔。用来判断是否该把工具栏收起来
    var onStrokeBegan: () -> Void = {}
    var onStrokeEnded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly      // 手指只用来滚动，笔才画
        canvas.tool = tool
        canvas.delegate = context.coordinator
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        // 画布固定尺寸，不允许用户缩放或滚动，
        // 否则双指捏合会变成整体平移，笔迹跟纸就错位了
        canvas.isScrollEnabled = false
        canvas.drawing = drawing

        // 双指捏合切工具。要求两个手指，避开单指滚动。
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        // 不要缩放：这块画布固定尺寸，缩放只会错位
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.addGestureRecognizer(pinch)
        context.coordinator.pinch = pinch

        // Pencil Pro 轻捏 / 轻点两下：UIPencilInteraction 是唯一的官方入口。
        // 挂到 window 上而不是 canvas —— 笔没落在画布上时也能收到轻捏。
        // 注意必须保持强引用，否则 interaction 会被释放，回调再也不来。
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        pencil.isEnabled = true
        context.coordinator.squeezeInteraction = pencil

        // 优先挂 window；还没进窗口就先挂 canvas，等 didMoveToWindow 再搬
        if let window = canvas.window {
            window.addInteraction(pencil)
            context.coordinator.pencilAttachedTo = .window
        } else {
            canvas.addInteraction(pencil)
            context.coordinator.pencilAttachedTo = .canvas
        }

        context.coordinator.startToolPolling(canvas)

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // 画布进窗口后，把轻捏交互从 canvas 搬到 window，
        // 这样笔没落在画布上也能收到。
        if context.coordinator.pencilAttachedTo == .canvas,
           let window = canvas.window,
           let p = context.coordinator.squeezeInteraction {
            canvas.removeInteraction(p)
            window.addInteraction(p)
            context.coordinator.pencilAttachedTo = .window
        }

        context.coordinator.applyToolIfNeeded(canvas, tool: tool)

        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            context.coordinator.isUpdating = true
            canvas.drawing = drawing
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: InkCanvasView
        var isUpdating = false
        private var lastToolSignature: String = ""
        weak var pinch: UIPinchGestureRecognizer?
        private var pinchFired = false
        private var squeezeHandled = false
        /// 强引用，防止 interaction 被释放
        var squeezeInteraction: UIPencilInteraction?
        enum PencilHost { case none, canvas, window }
        var pencilAttachedTo: PencilHost = .none
        /// 最近一次工具切换时间，防轻捏+双击双触发
        private var lastToggleAt: CFTimeInterval = 0
        private var toolPollTimer: Timer?
        /// 上一次见到的画布工具签名，用来判断"谁改了工具"
        private var canvasToolSignature = ""

        init(_ parent: InkCanvasView) { self.parent = parent }

        /// PKCanvasView.tool 不是 KVO 兼容属性（没有 @objc dynamic），
        /// 用 observe(\.tool) 会直接崩在 _bridgeKeyPathToString。
        /// 所以改成轻量轮询：每 0.15 秒比一次签名，变了就说明系统动了工具。
        func startToolPolling(_ canvas: PKCanvasView) {
            canvasToolSignature = signature(of: canvas.tool)
            toolPollTimer?.invalidate()
            toolPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self, weak canvas] _ in
                guard let self, let canvas else { return }
                let sig = self.signature(of: canvas.tool)
                guard sig != self.canvasToolSignature else { return }
                self.canvasToolSignature = sig
                self.lastToolSignature = sig
                // 系统轻捏把工具改了，同步回 SwiftUI
                if canvas.tool is PKEraserTool {
                    self.parent.onPinchToggleToolIfNeeded(true)
                } else if canvas.tool is PKInkingTool {
                    self.parent.onPinchToggleToolIfNeeded(false)
                }
            }
        }

        deinit { toolPollTimer?.invalidate() }

        /// PKTool 没有可比较的描述，自己拼一个签名
        private func signature(of tool: PKTool) -> String {
            if let pen = tool as? PKInkingTool {
                let c = pen.color
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                return String(format: "ink-%.3f-%.3f-%.3f-%.3f-%.2f-%@",
                              r, g, b, a, pen.width, String(describing: pen.inkType))
            }
            if tool is PKEraserTool { return "eraser" }
            if tool is PKLassoTool { return "lasso" }
            return "other"
        }

        func applyToolIfNeeded(_ canvas: PKCanvasView, tool: PKTool) {
            let sig = signature(of: tool)
            guard sig != lastToolSignature else { return }
            lastToolSignature = sig
            canvas.tool = tool
            canvasToolSignature = sig
        }

        // MARK: - 落笔 / 抬笔

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.onStrokeBegan()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.onStrokeEnded()
        }

        // MARK: - Apple Pencil 轻捏 / 轻点两下（UIPencilInteraction）

        /// 轻捏。Pencil Pro 才有。
        /// 用户偏好从 UIPencilInteraction.preferredSqueezeAction 读，
        /// 我们在系统设置里已经选成「切换当前工具和橡皮擦」。
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            // 文档：.ended =「连续手势结束，或离散手势被识别」。
            // 轻捏是离散手势，正常只发一次 .ended；
            // 但部分系统版本会先发 .began 再发 .ended，
            // 用 squeezeHandled 防重复，两种情况都能触发。
            switch squeeze.phase {
            case .began, .ended:
                if squeezeHandled { return }
                squeezeHandled = true
            case .cancelled:
                squeezeHandled = false
                return
            default:
                return
            }
            // 抬手后复位，下一次轻捏才能再触发
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.squeezeHandled = false
            }

            switch UIPencilInteraction.preferredSqueezeAction {
            case .switchEraser, .switchPrevious:
                fireToggle()
            case .showColorPalette, .showInkAttributes, .showContextualPalette:
                // 这些交给系统面板，不抢行为
                break
            default:
                break
            }
        }

        /// 轻点两下（Pencil 2 / Pencil Pro 都支持）。
        /// UIPencilInteraction.Tap 没有 phase 属性 —— 只在已经结束时回调一次，
        /// 所以这里直接处理，不用判相位。
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction,
                               didReceiveTap tap: UIPencilInteraction.Tap) {
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser, .switchPrevious:
                fireToggle()
            default:
                break
            }
        }

        /// 老的双击回调（iOS 12.1 起）。iOS 17.5+ 会被上面那个取代，
        /// 但低版本设备只有这个能收到。
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            if #available(iOS 17.5, *) { return }   // 新系统走带 Tap 的那个
            if UIPencilInteraction.preferredTapAction == .switchEraser {
                fireToggle()
            }
        }

        /// 所有「切换工具」路径的唯一出口：去抖 250ms，
        /// 避免轻捏和双击同时被系统上报时切两次。
        private func fireToggle() {
            let now = CACurrentMediaTime()
            guard now - lastToggleAt > 0.25 else { return }
            lastToggleAt = now
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            parent.onPinchToggleTool()
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                pinchFired = false
            case .changed:
                // 攥到 78% 以下才算数，避免误触
                if !pinchFired && g.scale < 0.75 {
                    pinchFired = true
                    fireToggle()
                }
            case .ended, .cancelled, .failed:
                pinchFired = false
            default:
                break
            }
        }

        /// 让捏合手势优先于画布的滚动/缩放
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isUpdating else { return }
            parent.drawing = canvasView.drawing
            parent.onDrawingChanged(canvasView.drawing)
        }
    }
}

// MARK: - 工具栏
struct InkToolbar: View {

    @Binding var tool: PKTool
    @Binding var color: Color
    @Binding var width: CGFloat
    @Binding var isEraser: Bool
    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onClear: () -> Void
    var onHide: () -> Void

    private let palette: [Color] = [.black, .red, .blue, .green, .orange, .purple]

    var body: some View {
        HStack(spacing: 10) {

            // 笔 / 橡皮
            HStack(spacing: 0) {
                segment(icon: "pencil.tip", active: !isEraser) {
                    isEraser = false
                    tool = PKInkingTool(.pen, color: UIColor(color), width: width)
                }
                segment(icon: "eraser", active: isEraser) {
                    isEraser = true
                    tool = PKEraserTool(.bitmap, width: 20.0)
                }
            }
            .background(Color.black.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Divider().frame(height: 22)

            // 颜色
            HStack(spacing: 8) {
                ForEach(palette.indices, id: \.self) { i in
                    Circle()
                        .fill(palette[i])
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(color == palette[i] ? 0.55 : 0),
                                              lineWidth: 2)
                                .padding(-3)
                        )
                        .onTapGesture {
                            color = palette[i]
                            isEraser = false
                            tool = PKInkingTool(.pen, color: UIColor(palette[i]), width: width)
                        }
                }
            }

            Divider().frame(height: 22)

            // 粗细
            HStack(spacing: 6) {
                ForEach([1.5, 3.0, 6.0], id: \.self) { w in
                    Circle()
                        .fill(Color.primary.opacity(width == CGFloat(w) ? 0.85 : 0.28))
                        .frame(width: CGFloat(w * 2.2), height: CGFloat(w * 2.2))
                        .frame(width: 26, height: 26)
                        .onTapGesture {
                            width = CGFloat(w)
                            isEraser = false
                            tool = PKInkingTool(.pen, color: UIColor(color), width: CGFloat(w))
                        }
                }
            }

            Divider().frame(height: 22)

            icon("arrow.uturn.backward", enabled: canUndo, action: onUndo)
            icon("arrow.uturn.forward", enabled: canRedo, action: onRedo)
            icon("trash", enabled: true, action: onClear)
            icon("chevron.up", enabled: true, action: onHide)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func segment(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 38, height: 32)
                .background(active ? Color.white : Color.clear)
                .foregroundStyle(active ? Color.black : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func icon(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
