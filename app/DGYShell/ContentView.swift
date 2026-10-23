import SwiftUI
import WebKit

// MARK: - 注入脚本
// 在每条视频下方插入「复制 + 跳转」按钮，点击后通过 messageHandler 交给原生处理
private let injectJS = #"""
(function(){
  if (window.__dgyInstalled) return;
  window.__dgyInstalled = true;

  var WRAP = 'dgy-bili-wrap';
  var BTN  = 'dgy-bili-copy';

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
    if (p.start_progress) out.push('start_progress=' + p.start_progress);
    else if (p.t) out.push('t=' + p.t);
    if (p.p) out.push('p=' + p.p);
    return 'bilibili://video/' + bv + (out.length ? '?' + out.join('&') : '');
  }

  function toWebUrl(href){
    var m = href.match(/\/video\/(BV[0-9A-Za-z]{10})\/?(\?[^#]*)?/);
    if (!m) return null;
    var bv = m[1], qs = m[2] || '', p = {};
    qs.replace(/^\?/,'').split('&').forEach(function(kv){
      if (!kv) return;
      var i = kv.indexOf('=');
      if (i > 0) p[kv.slice(0,i)] = kv.slice(i+1);
    });
    var out = [];
    if (p.t) out.push('t=' + p.t);
    if (p.p) out.push('p=' + p.p);
    if (p.start_progress) out.push('start_progress=' + p.start_progress);
    return 'https://www.bilibili.com/video/' + bv + '/' + (out.length ? '?' + out.join('&') : '');
  }

  function mkBtn(label, bg, color, onClick){
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.style.cssText = 'flex:1;background:' + bg + ';color:' + color + ';'
      + 'border:none;border-radius:8px;padding:10px 12px;font-size:13px;'
      + 'font-weight:600;cursor:pointer;font-family:-apple-system,sans-serif;';
    b.addEventListener('click', function(e){
      e.preventDefault(); e.stopPropagation(); onClick(b);
    });
    return b;
  }

  function decorate(li){
    if (li.querySelector('.' + BTN)) return;
    var a = li.querySelector('a[href*="/video/BV"]');
    if (!a) return;

    var scheme = toScheme(a.getAttribute('href'));
    var webUrl = toWebUrl(a.getAttribute('href'));
    if (!scheme) return;

    var wrap = document.createElement('div');
    wrap.className = WRAP;
    wrap.style.cssText = 'display:flex;gap:8px;margin:8px 0 0;width:100%;';

    var main = mkBtn('📋 复制 + 跳转', '#FB7299', '#fff', function(b){
      // 复制链接（给 PiliPlus 剪贴板兜底），再通知原生跳 scheme
      try {
        if (navigator.clipboard && navigator.clipboard.writeText && webUrl) {
          navigator.clipboard.writeText(webUrl);
        }
      } catch (e) {}

      window.webkit.messageHandlers.biliJump.postMessage(scheme);
      b.textContent = '✓ 已跳转';
      b.style.background = '#2ecc71';
      setTimeout(function(){
        b.textContent = '📋 复制 + 跳转';
        b.style.background = '#FB7299';
      }, 1800);
    });

    var only = document.createElement('button');
    only.type = 'button';
    only.textContent = '只复制';
    only.style.cssText = 'flex:0 0 auto;background:#fff;color:#FB7299;'
      + 'border:1px solid #FB7299;border-radius:8px;padding:10px 12px;'
      + 'font-size:13px;font-weight:600;cursor:pointer;'
      + 'font-family:-apple-system,sans-serif;';
    only.addEventListener('click', function(e){
      e.preventDefault(); e.stopPropagation();
      try {
        if (navigator.clipboard && navigator.clipboard.writeText && webUrl) {
          navigator.clipboard.writeText(webUrl).then(function(){
            only.textContent = '✓';
            setTimeout(function(){ only.textContent = '只复制'; }, 1500);
          });
          return;
        }
      } catch (err) {}
      if (webUrl) window.webkit.messageHandlers.biliCopy.postMessage(webUrl);
      only.textContent = '✓';
      setTimeout(function(){ only.textContent = '只复制'; }, 1500);
    });

    wrap.appendChild(main);
    wrap.appendChild(only);
    li.appendChild(wrap);
  }

  function scan(){
    var spans = document.querySelectorAll('a[href*="/video/BV"]');
    for (var i = 0; i < spans.length; i++) {
      var li = spans[i].closest('li');
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
        switch message.name {
        case "biliJump":
            guard let scheme = message.body as? String,
                  let url = URL(string: scheme) else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { ok in
                    NSLog("[DGYShell] open %@ -> %@", scheme, ok ? "ok" : "fail")
                }
            }

        case "biliCopy":
            guard let text = message.body as? String else { return }
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }

        default:
            break
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
        ucc.add(BiliBridge.shared, name: "biliCopy")
        ucc.addUserScript(WKUserScript(source: injectJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .systemBackground

        web.load(URLRequest(url: homeURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // 新窗口链接：在当前 webview 打开，避免跳 Safari
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                // bilibili scheme 交给原生
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
    @State private var showHome = true
    private let homeURL = URL(string: "https://www.cxyonly.fans/")!

    var body: some View {
        ZStack(alignment: .top) {
            WebShell(homeURL: homeURL)
                .id(reloadToken)
                .ignoresSafeArea(.all, edges: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                reloadToken = UUID()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color(red: 0.98, green: 0.45, blue: 0.60))
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .padding(.trailing, 16)
            .padding(.bottom, 24)
        }
    }
}
