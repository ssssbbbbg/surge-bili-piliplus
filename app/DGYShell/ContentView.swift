import SwiftUI
import WebKit

// MARK: - 注入脚本
// 把弹窗里每条视频右侧的 ↗ 箭头替换成「跳转」按钮，点击直接唤起 PiliPlus
private let injectJS = #"""
(function(){
  if (window.__dgyInstalled) return;
  window.__dgyInstalled = true;

  var MARK = 'data-dgy-jump';

  function parse(href){
    var m = href.match(/\/video\/(BV[0-9A-Za-z]{10})\/?(\?[^#]*)?/);
    if (!m) return null;
    var bv = m[1], qs = m[2] || '', p = {};
    qs.replace(/^\?/,'').split('&').forEach(function(kv){
      if (!kv) return;
      var i = kv.indexOf('=');
      if (i > 0) p[kv.slice(0,i)] = kv.slice(i+1);
    });
    return {bv: bv, p: p};
  }

  // 解析成原生需要的结构化数据：
  //   bvid      视频号
  //   page      分P 序号（第几P，从 1 开始）
  //   progress  进度毫秒（优先 start_progress）
  function toPayload(href){
    var d = parse(href);
    if (!d) return null;
    var out = {bvid: d.bv};
    if (d.p.p) {
      var page = parseInt(d.p.p, 10);
      if (!isNaN(page)) out.page = page;
    }
    if (d.p.start_progress) {
      var ms = parseInt(d.p.start_progress, 10);
      if (!isNaN(ms)) out.progress = ms;
    } else if (d.p.t) {
      var sec = parseFloat(d.p.t);
      if (!isNaN(sec)) out.progress = Math.round(sec * 1000);
    }
    return out;
  }

  // ---- cid 预取缓存 ----
  // 弹窗渲染时就查好 pagelist，点跳转直接查表，不再等网络
  var cidCache = {};      // bvid -> {page: cid}
  var cidPending = {};    // bvid -> true（请求进行中）
  var cidFailed = {};     // bvid -> true（已失败，别重复请求）

  function prefetch(bvid){
    if (!bvid) return;
    if (cidCache[bvid] || cidPending[bvid] || cidFailed[bvid]) return;
    cidPending[bvid] = true;

    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'https://api.bilibili.com/x/player/pagelist?bvid=' + bvid, true);
    xhr.timeout = 6000;
    xhr.onload = function(){
      delete cidPending[bvid];
      try {
        var r = JSON.parse(xhr.responseText);
        if (r.code === 0 && r.data && r.data.length) {
          var map = {};
          for (var i = 0; i < r.data.length; i++) {
            map[r.data[i].page] = r.data[i].cid;
          }
          cidCache[bvid] = map;
          // 缓存好了，把对应按钮点亮成「已就绪」
          markReady(bvid);
        } else {
          cidFailed[bvid] = true;
        }
      } catch(e) {
        cidFailed[bvid] = true;
      }
    };
    xhr.onerror = xhr.ontimeout = function(){
      delete cidPending[bvid];
      cidFailed[bvid] = true;
    };
    try { xhr.send(); } catch(e) { delete cidPending[bvid]; cidFailed[bvid] = true; }
  }

  function markReady(bvid){
    var btns = document.querySelectorAll('[' + MARK + ']');
    for (var i = 0; i < btns.length; i++) {
      if (btns[i].getAttribute('data-bvid') === bvid) {
        btns[i].setAttribute('data-ready', '1');
      }
    }
  }

  function buildBtn(scheme, payload){
    var b = document.createElement('button');
    b.type = 'button';
    b.setAttribute(MARK, '1');   // ← 关键：打标记，去重就靠它
    if (payload && payload.bvid) b.setAttribute('data-bvid', payload.bvid);
    b.title = '\u8DF3\u8F6C\u5230 PiliPlus';
    b.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" '
      + 'viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" '
      + 'stroke-linecap="round" stroke-linejoin="round">'
      + '<path d="M7 17 L17 7"/><path d="M9 7 L17 7 L17 15"/></svg>';
    b.style.cssText =
      'display:flex;align-items:center;justify-content:center;' +
      'width:34px;height:34px;padding:0;border:none;border-radius:9px;' +
      'background:#FB7299;color:#fff;cursor:pointer;' +
      'box-shadow:0 2px 8px rgba(251,114,153,.35);' +
      '-webkit-tap-highlight-color:transparent;flex:0 0 auto;';
    b.addEventListener('click', function(e){
      e.preventDefault();
      e.stopPropagation();

      var bvid = payload.bvid;
      var map = cidCache[bvid];

      // 命中缓存：直接跳，零等待
      if (map && payload.page && map[payload.page]) {
        var direct = {bvid: bvid, cid: map[payload.page], __fromJS: 1};
        if (payload.progress) direct.progress = payload.progress;
        window.webkit.messageHandlers.biliJump.postMessage(direct);
        b.style.background = '#2ecc71';
        setTimeout(function(){ b.style.background = '#FB7299'; }, 900);
        return;
      }

      // 未命中：发起请求，成功再跳
      var sent = false;
      function send(obj){
        if (sent) return;
        sent = true;
        obj.__fromJS = true;
        window.webkit.messageHandlers.biliJump.postMessage(obj);
        b.style.background = '#2ecc71';
        setTimeout(function(){ b.style.background = '#FB7299'; }, 900);
      }

      if (payload.page && payload.page > 1 && !cidFailed[bvid]) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', 'https://api.bilibili.com/x/player/pagelist?bvid=' + bvid, true);
        xhr.timeout = 4000;
        xhr.onload = function(){
          try {
            var r = JSON.parse(xhr.responseText);
            if (r.code === 0 && r.data) {
              var m = {};
              for (var i = 0; i < r.data.length; i++) m[r.data[i].page] = r.data[i].cid;
              cidCache[bvid] = m;
              if (m[payload.page]) {
                payload.cid = m[payload.page];
                send(payload);
                return;
              }
            }
          } catch(e) {}
          cidFailed[bvid] = true;
          send(payload);
        };
        xhr.onerror = xhr.ontimeout = function(){ cidFailed[bvid] = true; send(payload); };
        try { xhr.send(); } catch(e) { send(payload); }
      } else {
        send(payload);
      }
    });
    return b;
  }

  function decorate(li){
    var a = li.querySelector('a[href*="/video/BV"]');
    if (!a) return;

    // 已经插过就跳过（按钮自带 MARK）
    if (a.querySelector('[' + MARK + ']')) return;

    var payload = toPayload(a.getAttribute('href'));
    if (!payload) return;

    // 弹窗渲染时就开始预取 cid，点跳转时零等待
    prefetch(payload.bvid);

    var btn = buildBtn(null, payload);

    // 定位：主 a 里的 ↗ 箭头（class = svg.tabler-icon-arrow-up-right）
    // 用 getAttribute 读 class —— svg 的 className 是 SVGAnimatedString，直接取会得到对象
    var arrow = a.querySelector('svg.tabler-icon-arrow-up-right');
    if (!arrow) {
      // 兜底：取 a 内最后一个非 bilibili 图标的 svg
      var svgs = a.querySelectorAll('svg');
      for (var i = svgs.length - 1; i >= 0; i--) {
        var cls = svgs[i].getAttribute('class') || '';
        if (cls.indexOf('brand-bilibili') < 0) { arrow = svgs[i]; break; }
      }
    }
    if (arrow) {
      arrow.replaceWith(btn);
      return;
    }

    // 兜底：绝对定位到 li 右上角
    var cs = getComputedStyle(li);
    if (cs.position === 'static') li.style.position = 'relative';
    btn.style.position = 'absolute';
    btn.style.top = '10px';
    btn.style.right = '12px';
    li.appendChild(btn);
  }

  function scan(){
    var as = document.querySelectorAll('a[href*="/video/BV"]');
    for (var i = 0; i < as.length; i++) {
      var li = as[i].closest('li');
      if (li) decorate(li);
    }
  }

  var timer = null;
  function schedule(){
    if (timer) return;
    timer = setTimeout(function(){ timer = null; scan(); }, 180);
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule);
  } else {
    schedule();
  }
})();
"""#

// MARK: - 原生桥
final class BiliBridge: NSObject, WKScriptMessageHandler {
    static let shared = BiliBridge()

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "biliJump" else { return }
        guard let body = message.body as? [String: Any] else {
            NSLog("[DGYShell] bad body: %@", String(describing: message.body))
            return
        }
        guard let bvid = body["bvid"] as? String else {
            NSLog("[DGYShell] missing bvid: %@", String(describing: body))
            return
        }

        // JS 数字桥接成 NSNumber，as? Int 不可靠，统一走 NSNumber
        let page: Int? = (body["page"] as? NSNumber)?.intValue
        let progress: Int? = (body["progress"] as? NSNumber)?.intValue

        DLog("收到跳转: bvid=\(bvid) page=\(page.map(String.init) ?? "nil") progress=\(progress.map(String.init) ?? "nil")")
        DLog("原始 body: \(body)")

        // JS 侧已拿到 cid 就直接用，跳过原生请求
        if let cid = (body["cid"] as? NSNumber)?.intValue {
            var qs = ["cid=\(cid)"]
            if let progress = progress { qs.append("start_progress=\(progress)") }
            let final = "bilibili://video/\(bvid)?" + qs.joined(separator: "&")
            DLog("JS 已给 cid=\(cid)，直接跳: \(final)")
            guard let url = URL(string: final) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { ok in
                    DLog("openURL 结果: \(ok ? "成功" : "失败")")
                }
            }
            return
        }

        // PiliPlus 的 bilibili:// 入口会丢 p 参数（源码 bug），
        // 所以这里先把分P换成 cid，走带 cid 的入口。
        DLog("JS 没给 cid，原生开始解析 ...")
        CidResolver.resolve(bvid: bvid, page: page, progress: progress) { scheme in
            let final = scheme ?? {
                DLog("cid 解析失败，回退到原 scheme")
                var qs: [String] = []
                if let progress = progress { qs.append("start_progress=\(progress)") }
                if let page = page { qs.append("p=\(page)") }
                return "bilibili://video/\(bvid)" + (qs.isEmpty ? "" : "?" + qs.joined(separator: "&"))
            }()

            DLog("最终 scheme: \(final)")
            guard let url = URL(string: final) else {
                DLog("URL 构造失败")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { ok in
                    DLog("openURL 结果: \(ok ? "成功" : "失败")")
                }
            }
        }
    }
}
// MARK: - WebView 容器（全屏）
struct WebShell: UIViewRepresentable {
    let homeURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let ucc = cfg.userContentController
        ucc.add(BiliBridge.shared, name: "biliJump")
        ucc.addUserScript(WKUserScript(source: injectJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = true
        web.backgroundColor = .systemBackground

        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.contentInset = .zero
        web.scrollView.scrollIndicatorInsets = .zero
        web.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        if #available(iOS 15.0, *) {
            web.underPageBackgroundColor = .systemBackground
        }

        web.load(URLRequest(url: homeURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                let s = url.scheme ?? ""
                if s != "http" && s != "https" && s != "about" && s != "file" {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    return nil
                }
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let s = url.scheme ?? ""
            if s == "http" || s == "https" || s == "about" || s == "file" || s == "data" {
                decisionHandler(.allow)
                return
            }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 主界面（全屏）
struct ContentView: View {
    @State private var reloadToken = UUID()
    @State private var showLog = false
    private let homeURL = URL(string: "https://www.cxyonly.fans/")!

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebShell(homeURL: homeURL)
                .id(reloadToken)
                .edgesIgnoringSafeArea(.all)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    showLog = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                }

                Button {
                    reloadToken = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color(red: 0.98, green: 0.45, blue: 0.60).opacity(0.92))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                }
            }
            .padding(.trailing, 14)
            .padding(.bottom, 34)
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }
}

// MARK: - 日志面板
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("跳转链路日志。点了没反应就看这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if lines.isEmpty {
                        Text("暂无日志").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") {
                        DLogStore.shared.clear()
                        lines = []
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("刷新") {
                        lines = DLogStore.shared.snapshot()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                DLogStore.shared.loadFromFile()
                lines = DLogStore.shared.snapshot()
            }
        }
    }
}
