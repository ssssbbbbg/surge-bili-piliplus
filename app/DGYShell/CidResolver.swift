import Foundation

/// 通过 B 站公开接口把 BV + 分P 换成 cid
/// PiliPlus 的 bilibili:// 入口会丢 p 参数（源码 bug），
/// 但带 cid 的入口会直接进 toVideoPage，不受影响。
enum CidResolver {

    /// 接口返回：{"code":0,"data":[{"cid":..,"page":..}, ...]}
    /// 注意 data 是数组，不是对象
    private struct PageList: Decodable {
        struct Page: Decodable {
            let cid: Int
            let page: Int
        }
        let code: Int
        let data: [Page]?
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
            DLog("cid: URL 构造失败")
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        DLog("cid: 请求 \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                let ns = error as NSError
                DLog("cid: 失败 domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)")
                completion(nil)
                return
            }
            if let http = response as? HTTPURLResponse {
                DLog("cid: HTTP \(http.statusCode)")
            }
            guard let data = data else {
                DLog("cid: 无数据返回")
                completion(nil)
                return
            }
            DLog("cid: 收到 \(data.count) 字节")

            guard let resp = try? JSONDecoder().decode(PageList.self, from: data) else {
                let raw = String(data: data.prefix(200), encoding: .utf8) ?? "bin"
                DLog("cid: JSON 解析失败 \(raw)")
                completion(nil)
                return
            }
            guard resp.code == 0 else {
                DLog("cid: 接口返回 code=\(resp.code)")
                completion(nil)
                return
            }
            guard let pages = resp.data, !pages.isEmpty else {
                DLog("cid: pages 为空")
                completion(nil)
                return
            }

            var map: [Int: Int] = [:]
            for p in pages { map[p.page] = p.cid }

            lock.lock()
            cache[bvid] = map
            lock.unlock()

            if let cid = map[page] {
                DLog("cid: page=\(page) 共\(pages.count)P -> cid=\(cid)")
                completion(scheme(bvid: bvid, cid: cid, progress: progress))
            } else {
                DLog("cid: 找不到 page=\(page)，共\(pages.count)P")
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
