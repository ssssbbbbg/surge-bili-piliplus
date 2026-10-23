import Foundation
import os.log

/// 轻量日志：同时写 NSLog、系统日志、以及沙盒内的 dgyshell.log
/// 自签安装连不上 Xcode 时，可以在 App 内「日志」面板查看。
final class DLogStore {
    static let shared = DLogStore()

    private init() {}

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxKeep = 400

    private lazy var fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("dgyshell.log")
    }()

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func append(_ msg: String) {
        let line = "[\(fmt.string(from: Date()))] \(msg)"
        lock.lock()
        lines.append(line)
        if lines.count > maxKeep { lines.removeFirst(lines.count - maxKeep) }
        let snapshot = lines
        lock.unlock()

        NSLog("[DGYShell] %@", msg)
        os_log("%{public}@", log: .default, type: .default, msg)

        // 追写文件（忽略失败）
        let text = snapshot.joined(separator: "\n") + "\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    var filePath: String { fileURL.path }

    /// 启动时把上次日志读回来
    func loadFromFile() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let arr = text.split(separator: "\n").map(String.init)
        lock.lock()
        lines = Array(arr.suffix(maxKeep))
        lock.unlock()
    }
}

func DLog(_ msg: String) {
    DLogStore.shared.append(msg)
}
