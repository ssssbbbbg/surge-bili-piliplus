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

  function toScheme(href){
    var d = parse(href);
    if (!d) return null;
    var out = [];
    if (d.p.start_progress) out.push('start_progress=' + d.p.start_progress);
    else if (d.p.t) out.push('t=' + d.p.t);
    if (d.p.p) out.push('p=' + d.p.p);
    return 'bilibili://video/' + d.bv + (out.length ? '?' + out.join('&') : '');
  }

  function buildBtn(scheme){
    var b = document.createElement('button');
    b.type = 'button';
    b.setAttribute(MARK, scheme);
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
      window.webkit.messageHandlers.biliJump.postMessage(scheme);
      b.style.background = '#2ecc71';
      setTimeout(function(){ b.style.background = '#FB7299'; }, 900);
    });
    return b;
  }

  function decorate(li){
    var a = li.querySelector('a[href*="/video/BV"]');
    if (!a) return;
    if (li.querySelector('[' + MARK + ']')) return;

    // 已有旧的复制按钮就清掉
    li.querySelectorAll('.dgy-bili-wrap').forEach(function(n){ n.remove(); });

    var scheme = toScheme(a.getAttribute('href'));
    if (!scheme) return;

    var btn = buildBtn(scheme);

    // 定位：主 a 里的最后一个 svg 就是 ↗ 箭头（实际没有 class，不能靠 class 选）
    var svgs = a.querySelectorAll(':scope > svg');
    var arrow = null;
    for (var i = svgs.length - 1; i >= 0; i--) {
      if ((svgs[i].getAttribute('class') || '').indexOf('brand-bilibili') < 0) {
        arrow = svgs[i];
        break;
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
        guard message.name == "biliJump",
              let scheme = message.body as? String,
              let url = URL(string: scheme) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                NSLog("[DGYShell] open %@ -> %@", scheme, ok ? "ok" : "fail")
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
        .statusBarHidden(true)
    }
}
