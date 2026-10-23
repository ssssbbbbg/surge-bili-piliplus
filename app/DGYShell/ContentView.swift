import SwiftUI
import WebKit

// MARK: - 注入脚本
private let injectJS = #"""
(function(){
  if (window.__dgyInstalled) return;
  window.__dgyInstalled = true;

  var WRAP = 'dgy-bili-wrap';
  var BTN  = 'dgy-bili-copy';

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

  function toScheme(href){
    var d = parse(href);
    if (!d) return null;
    var out = [];
    if (d.p.start_progress) out.push('start_progress=' + d.p.start_progress);
    else if (d.p.t) out.push('t=' + d.p.t);
    if (d.p.p) out.push('p=' + d.p.p);
    return 'bilibili://video/' + d.bv + (out.length ? '?' + out.join('&') : '');
  }

  function toWebUrl(href){
    var d = parse(href);
    if (!d) return null;
    var out = [];
    if (d.p.t) out.push('t=' + d.p.t);
    if (d.p.p) out.push('p=' + d.p.p);
    if (d.p.start_progress) out.push('start_progress=' + d.p.start_progress);
    return 'https://www.bilibili.com/video/' + d.bv + '/' + (out.length ? '?' + out.join('&') : '');
  }

  function mkBtn(label, bg, color, border, onClick){
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.style.cssText = 'flex:0 0 auto;background:' + bg + ';color:' + color + ';'
      + 'border:' + (border ? '1px solid ' + color : 'none') + ';'
      + 'border-radius:8px;padding:9px 14px;font-size:13px;font-weight:600;'
      + 'line-height:1.2;cursor:pointer;font-family:-apple-system,sans-serif;'
      + 'white-space:nowrap;';
    b.addEventListener('click', function(e){
      e.preventDefault(); e.stopPropagation(); onClick(b);
    });
    return b;
  }

  function resetBtn(b, label, bg){
    b.textContent = label;
    b.style.background = bg;
  }

  function decorate(li){
    if (li.dataset.dgyDone === '1') return;
    var a = li.querySelector('a[href*="/video/BV"]');
    if (!a) return;

    var scheme = toScheme(a.getAttribute('href'));
    var webUrl = toWebUrl(a.getAttribute('href'));
    if (!scheme) return;

    li.querySelectorAll('.' + WRAP).forEach(function(n){ n.remove(); });
    li.dataset.dgyDone = '1';

    var wrap = document.createElement('div');
    wrap.className = WRAP;
    wrap.style.cssText = 'display:flex;flex-direction:row;flex-wrap:wrap;'
      + 'gap:8px;width:100%;margin:10px 0 4px;align-items:center;';

    // 主按钮：复制 + 跳转
    var main = mkBtn('\uD83D\uDCCB \u590D\u5236 + \u8DF3\u8F6C', '#FB7299', '#fff', false, function(b){
      try {
        if (navigator.clipboard && navigator.clipboard.writeText && webUrl) {
          navigator.clipboard.writeText(webUrl);
        }
      } catch (e) {}
      window.webkit.messageHandlers.biliJump.postMessage(scheme);
      b.textContent = '\u2713 \u5DF2\u8DF3\u8F6C';
      b.style.background = '#2ecc71';
      setTimeout(function(){ resetBtn(b, '\uD83D\uDCCB \u590D\u5236 + \u8DF3\u8F6C', '#FB7299'); }, 1800);
    });

    // 次按钮：只复制
    var only = mkBtn('\u53EA\u590D\u5236', '#fff', '#FB7299', true, function(b){
      var done = function(){
        b.textContent = '\u2713';
        setTimeout(function(){ b.textContent = '\u53EA\u590D\u5236'; }, 1500);
      };
      try {
        if (navigator.clipboard && navigator.clipboard.writeText && webUrl) {
          navigator.clipboard.writeText(webUrl).then(done).catch(function(){
            window.webkit.messageHandlers.biliCopy.postMessage(webUrl);
            done();
          });
          return;
        }
      } catch (err) {}
      if (webUrl) window.webkit.messageHandlers.biliCopy.postMessage(webUrl);
      done();
    });

    wrap.appendChild(main);
    wrap.appendChild(only);
    li.appendChild(wrap);
  }

  function scan(){
    // 清孤儿
    document.querySelectorAll('.' + WRAP).forEach(function(w){
      var li = w.closest('li');
      if (!li || !li.querySelector('a[href*="/video/BV"]')) w.remove();
    });
    var as = document.querySelectorAll('a[href*="/video/BV"]');
    for (var i = 0; i < as.length; i++) {
      var li = as[i].closest('li');
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
        ucc.add(BiliBridge.shared, name: "biliCopy")
        ucc.addUserScript(WKUserScript(source: injectJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = true
        web.backgroundColor = .systemBackground

        // 全屏关键三项
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
    private let homeURL = URL(string: "https://www.cxyonly.fans/")!

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebShell(homeURL: homeURL)
                .id(reloadToken)
                .edgesIgnoringSafeArea(.all)

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
            .padding(.trailing, 14)
            .padding(.bottom, 34)
        }
    }
}
