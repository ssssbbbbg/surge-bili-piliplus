import SwiftUI
import PencilKit

// MARK: - PencilKit 画布
// 覆盖在网页作答区上方。原生笔迹：压感、倾斜、平滑、防误触都是系统级。
struct InkCanvasView: UIViewRepresentable {

    @Binding var drawing: PKDrawing
    @Binding var tool: PKTool
    var onDrawingChanged: (PKDrawing) -> Void

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
        canvas.contentSize = UIScreen.main.bounds.size
        canvas.drawing = drawing

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.applyToolIfNeeded(canvas, tool: tool)

        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            context.coordinator.isUpdating = true
            canvas.drawing = drawing
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: InkCanvasView
        var isUpdating = false
        private var lastToolSignature: String = ""

        init(_ parent: InkCanvasView) { self.parent = parent }

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
    var onFit: () -> Void

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
                    if #available(iOS 16.4, *) {
                        tool = PKEraserTool(.bitmap, width: 20.0 as CGFloat)
                    } else {
                        tool = PKEraserTool(.bitmap)
                    }
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
            icon("arrow.down.right.and.arrow.up.left", enabled: true, action: onFit)

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
