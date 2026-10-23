import SwiftUI
import WebKit

// MARK: - 注入脚本
// 在每条视频下方插入「打开 PiliPlus」按钮，点击后交给原生直接跳转
// 不复制、不弹任何中间态
private let injectJS = #"""
(function(){
  if (window.__dgyInstalled) return;
  window.__dgyInstalled = true;

  var WRAP = 'dgy-bili-wrap';
  var KEY  = 'dgyDone';

  // 网页链接 -> bilibili:// scheme（PiliPlus 认的格式）
  function toScheme(href){
    var m = href.match(/\/video\/(BV[0-9A-Za-z]{10})\/?(\?[^#]*)?/);
    if (!m) return null;
    var bv = m[1], qs = m[2] || '', p = {};
    qs.replace(/^\?/,'').split('&').forEach(function(kv){
      if (!kv) return;
      var i = kv.indexOf('=');
      if (i > 0) p[kv.slice(0,i)] = kv.slice(i+1);
    });
    var out = [];
    // start_progress 是毫秒，PiliPlus 优先用它
    if (p.start_progress) out.push('start_progress=' + p.start_progress);
    else if (p.t) out.push('t=' + p.t);
    if (p.p) out.push('p=' + p.p);
    return 'bilibili://video/' + bv + (out.length ? '?' + out.join('&') : '');
  }

  function decorate(li){
    if (li.dataset[KEY] === '1') return;

    var a = li.querySelector('a[href*="/video/BV"]');
    if (!a) return;

    var scheme = toScheme(a.getAttribute('href'));
    if (!scheme) return;

    li.dataset[KEY] = '1';

    var wrap = document.createElement('div');
    wrap.className = WRAP;
    wrap.style.cssText = 'display:block;margin:10px 0 4px;width:100%;';

    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = '▶ 打开 PiliPlus';
    b.style.cssText = 'display:block;width:100%;background:#FB7299;color:#fff;'
      + 'border:none;border-radius:8px;padding:12px 14px;font-size:14px;'
      + 'font-weight:600;cursor:pointer;font-family:-apple-system,sans-serif;';

    b.addEventListener('click', function(e){
      e.preventDefault();
      e.stopPropagation();

      // 交给原生：WKWebView 里 openURL 不弹确认框
      window.webkit.messageHandlers.biliJump.postMessage(scheme);

      b.textContent = '✓ 正在打开…';
      b.style.background = '#2ecc71';
      setTimeout(function(){
        b.textContent = '▶ 打开 PiliPlus';
        b.style.background = '#FB7299';
      }, 2000);
    });

    wrap.appendChild(b);
    li.appendChild(wrap);
  }

  function scan(){
    // 清理孤儿：li 还在但按钮重复的
    document.querySelectorAll('.' + WRAP).forEach(function(w){
      var li = w.closest('li');
      if (!li || !li.querySelector('a[href*="/video/BV"]')) w.remove();
      else if (w.parentNode && w.parentNode.querySelectorAll('.' + WRAP).length > 1) w.remove();
    });
    var links = document.querySelectorAll('a[href*="/video/BV"]');
    for (var i = 0; i < links.length; i++) {
      var li = links[i].closest('li');
      if (li) decorate(li);
    }
  }

  var timer = null;
  function schedule(){
    if (timer) return;
    timer = setTimeout(function(){ timer = null; scan(); }, 200);
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
        guard let scheme = message.body as? String,
              let url = URL(string: scheme) else { return }

        // 关键：原生调用，绕开 Safari，无确认框
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                NSLog("[DGYShell] open %@ -> %@", scheme, ok ? "ok" : "fail")
            }
        }
    }
}

// MARK: - WebView 容器
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
        // 兜底：页面自带 viewport 导致左右留白/缩放时强制铺满
        let vpJS = """
        (function(){
          var m = document.querySelector('meta[name=viewport]');
          if (!m) { m = document.createElement('meta'); m.setAttribute('name','viewport'); document.head.appendChild(m); }
          m.setAttribute('content','width=device-width, initial-scale=1.0, maximum-scale=1.0, viewport-fit=cover');
          document.documentElement.style.overflowX='hidden';
        })();
        """
        ucc.addUserScript(WKUserScript(source: vpJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true

        // 全屏：忽略安全区、贴边
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.contentInset = .zero
        web.scrollView.scrollIndicatorInsets = .zero
        web.scrollView.bounces = true
        web.isOpaque = true
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground

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
                if let s = url.scheme, s != "http", s != "https", s != "about" {
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
            if s == "http" || s == "https" || s == "about" || s == "file" {
                decisionHandler(.allow)
                return
            }
            // 自定义 scheme：原生打开，不经过 Safari，无确认框
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 主界面
struct ContentView: View {
    @State private var reloadToken = UUID()
    private let homeURL = URL(string: "https://www.cxyonly.fans/")!

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geo in
                WebShell(homeURL: homeURL)
                    .id(reloadToken)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .ignoresSafeArea(.all, edges: .all)
            }
            .ignoresSafeArea(.all, edges: .all)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            Button {
                reloadToken = UUID()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(red: 0.98, green: 0.45, blue: 0.60).opacity(0.85))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .padding(.trailing, 14)
            .padding(.bottom, 18)
            .ignoresSafeArea(.all, edges: .bottom)
        }
        .ignoresSafeArea(.all, edges: .all)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(false)
    }
}
