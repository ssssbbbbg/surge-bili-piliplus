import Foundation
import PencilKit
import CryptoKit

/// 每道题的笔迹按 key 存成一个 .pkdrawing 文件，附一个 meta.json 记录页面信息。
/// 存沙盒 Application Support/Ink/ 下，iTunes 备份会带上。
final class InkStore {

    static let shared = InkStore()

    private let root: URL
    private let fm = FileManager.default
    private var cache: [String: PKDrawing] = [:]
    private var meta: [String: Meta] = [:]

    struct Meta: Codable {
        var key: String
        var title: String
        var source: String
        var updated: Date
        var strokes: Int
    }

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Ink", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        loadMeta()
    }

    // MARK: - 路径

    private func url(for key: String) -> URL {
        root.appendingPathComponent(Self.sanitize(key)).appendingPathExtension("pkdrawing")
    }

    private func metaURL() -> URL {
        root.appendingPathComponent("meta.json")
    }

    static func sanitize(_ key: String) -> String {
        // 只留 ASCII 安全字符，超长就取 hash，避免文件名爆掉
        var out = ""
        for ch in key.unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) || ch == "-" || ch == "_" || ch == "." {
                out.unicodeScalars.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.count > 80 {
            let h = SHA256.hash(data: Data(key.utf8))
            out = out.prefix(40) + "-" + h.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        }
        return out.isEmpty ? "untitled" : out
    }

    /// 用 URL 路径 + 页内题号拼一个稳定 key。
    /// 同一道题不管从哪进来，key 都一样，笔迹就能复用。
    static func makeKey(host: String, path: String, questionID: String?) -> String {
        let p = path.isEmpty ? "/" : path
        if let q = questionID, !q.isEmpty {
            return "\(host)\(p)#\(q)"
        }
        return "\(host)\(p)"
    }

    // MARK: - 读写

    func load(_ key: String) -> PKDrawing {
        if let c = cache[key] { return c }
        let u = url(for: key)
        guard let data = try? Data(contentsOf: u),
              let d = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        cache[key] = d
        return d
    }

    @discardableResult
    func save(_ drawing: PKDrawing, key: String, title: String, source: String) -> Bool {
        cache[key] = drawing
        let u = url(for: key)
        do {
            try drawing.dataRepresentation().write(to: u, options: .atomic)
            meta[key] = Meta(key: key,
                             title: title,
                             source: source,
                             updated: Date(),
                             strokes: drawing.strokes.count)
            persistMeta()
            return true
        } catch {
            return false
        }
    }

    func meta(for key: String) -> Meta? { meta[key] }

    func allKeys() -> [Meta] {
        meta.values.sorted { $0.updated > $1.updated }
    }

    func delete(_ key: String) {
        cache.removeValue(forKey: key)
        meta.removeValue(forKey: key)
        try? fm.removeItem(at: url(for: key))
        persistMeta()
    }

    func totalBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey]), let s = v.fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    // MARK: - meta

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL()),
              let list = try? JSONDecoder().decode([Meta].self, from: data) else { return }
        meta = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }

    private func persistMeta() {
        let list = Array(meta.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: metaURL(), options: .atomic)
    }
}
