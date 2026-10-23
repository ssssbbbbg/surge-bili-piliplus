import Foundation

/// 通过 B 站公开接口把 BV + 分P 换成 cid
/// PiliPlus 的 bilibili:// 入口会丢 p 参数（源码 bug），
/// 但带 cid 的入口会直接进 toVideoPage，不受影响。
enum CidResolver {

    private struct PageList: Decodable {
        struct DataBox: Decodable {
            let pages: [Page]?
        }
        struct Page: Decodable {
            let cid: Int
            let page: Int
        }
        let code: Int
        let data: DataBox?
    }

    /// 同步取消用：按 bvid 缓存所有分P，避免重复请求
    private static var cache: [String: [Int: Int]] = [:]  // bvid -> [page: cid]
    private static let lock = NSLock()

    /// 异步解析。成功回调 scheme；失败回调 nil（由调用方回退到原 scheme）
    static func resolve(bvid: String,
                        page: Int?,
                        progress: Int?,
                        completion: @escaping (String?) -> Void) {

        // 没有分P需求，直接走原 scheme
        guard let page = page, page > 1 else {
            completion(scheme(bvid: bvid, cid: nil, progress: progress))
            return
        }

        lock.lock()
        let cached = cache[bvid]
        lock.unlock()

        if let cached = cached, let cid = cached[page] {
            completion(scheme(bvid: bvid, cid: cid, progress: progress))
            return
        }

        guard let url = URL(string: "https://api.bilibili.com/x/player/pagelist?bvid=\(bvid)") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
                     forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let resp = try? JSONDecoder().decode(PageList.self, from: data),
                  resp.code == 0,
                  let pages = resp.data?.pages
            else {
                completion(nil)
                return
            }

            var map: [Int: Int] = [:]
            for p in pages { map[p.page] = p.cid }

            lock.lock()
            cache[bvid] = map
            lock.unlock()

            if let cid = map[page] {
                completion(scheme(bvid: bvid, cid: cid, progress: progress))
            } else {
                completion(nil)
            }
        }.resume()
    }

    private static func scheme(bvid: String, cid: Int?, progress: Int?) -> String {
        var qs: [String] = []
        if let cid = cid { qs.append("cid=\(cid)") }
        if let progress = progress { qs.append("start_progress=\(progress)") }
        return "bilibili://video/\(bvid)" + (qs.isEmpty ? "" : "?" + qs.joined(separator: "&"))
    }
}
