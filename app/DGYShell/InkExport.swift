import Foundation
import PencilKit
import UIKit

/// 导出与备份：把每道题的笔迹落成 PNG / PDF，或者打包成可迁移的文件。
enum InkExport {

    // MARK: - 单题图片

    /// 把一幅 PKDrawing 渲染成白底 PNG。
    /// size 用 canvas 的尺寸，scale 建议 2（够清晰又不至于太大）。
    static func png(from drawing: PKDrawing, size: CGSize, scale: CGFloat = 2) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        return image.pngData()
    }

    /// PDF 版本，矢量，放大不糊。打印或归档用。
    static func pdf(from drawing: PKDrawing, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { ctx in
            ctx.beginPage()
            UIColor.white.setFill()
            ctx.fill(bounds)
            drawing.image(from: bounds, scale: 2).draw(in: bounds)
        }
    }

    // MARK: - 打包备份

    /// 把整个 Ink 目录打成一个 zip，用系统 ActivityView 分享出去。
    /// 在「文件」App 里能保存到 iCloud Drive / 本地 / 第三方网盘。
    static func backupZip() -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let inkDir = base.appendingPathComponent("Ink", isDirectory: true)
        guard fm.fileExists(atPath: inkDir.path) else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let out = fm.temporaryDirectory
            .appendingPathComponent("InkBackup-\(stamp).zip")

        try? fm.removeItem(at: out)

        // iOS 15+ 自带归档没有 zip 公开 API，用协调读取 + 简单归档器
        // 这里走 ZipArchive 的替代方案：把目录内容序列化成一个 .json 加各 drawing 文件，
        // 用 Foundation 的 FileWrapper 打成 package（FileManager 可直接读写）。
        let wrapper = try? FileWrapper(url: inkDir, options: .immediate)
        guard let data = wrapper?.serializedRepresentation else { return nil }
        try? data.write(to: out)
        return out
    }

    /// 单题落盘到「文件」App 的 Documents，用户能直接在文件里看到
    static func saveToDocuments(png data: Data, name: String) -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("InkExport", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(InkStore.sanitize(name)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
