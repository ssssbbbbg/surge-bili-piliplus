import Foundation
import WebKit
import SwiftUI
import PencilKit

// MARK: - 注入脚本
// 目标站：https://www.cxyonly.fans/math/practice
// 结构（2026-10 实测）：
//   题号    : strong[class*="_number_"]          文本 = "1"
//   右栏容器: div[class*="_answerCanvas_"]
//   纸张    : div[class*="_paper_"]  (里面是 SVG 折线填充的笔迹)
//   左栏画布: div[class*="_canvas_"]  (题目上的圈画层，保留不动)
//
// 这个脚本做三件事：
//   1. 隐藏网站自带的作答区（它用 fill 折线画，锯齿很重）
//   2. 把作答区的位置量出来，报给原生
//   3. 题号变了就通知原生，用来切笔迹存档
let inkBootstrapJS = #"""
(function () {
  if (window.__inkHooked) { window.__inkMeasure && window.__inkMeasure(); return; }
  window.__inkHooked = true;

  var lastQ = null;

  function qnum() {
    var el = document.querySelector('strong[class*="_number_"]');
    var t = el ? el.textContent.trim() : '';
    return /^\d{1,5}$/.test(t) ? t : '';
  }

  function answerBox() {
    var el = document.querySelector('div[class*="_answerCanvas_"]');
    if (!el) return null;
    var r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 40) return null;
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  }

  function hideNative() {
    var el = document.querySelector('div[class*="_answerCanvas_"]');
    if (!el) return;
    if (el.__inkHidden) return;
    el.__inkHidden = true;

    // 把整个作答区变成透明占位：保留布局、不吃指针事件
    // 用 visibility 而不是 display，避免右侧面板布局塌掉
    el.style.visibility = 'hidden';
    el.style.pointerEvents = 'none';

    // 里面的 SVG 也盖上
    el.querySelectorAll('svg').forEach(function (s) {
      s.style.visibility = 'hidden';
    });
  }

  function measure() {
    hideNative();
    var box = answerBox();
    var q = qnum();
    var payload = { box: box, q: q, path: location.pathname, host: location.host,
                    ready: !!box };
    try {
      window.webkit.messageHandlers.ink.postMessage(payload);
    } catch (e) {}
    lastQ = q;
  }
  window.__inkMeasure = measure;

  // 题号/布局变化时重新量
  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () {
      pending = false;
      measure();
    });
  }

  var mo = new MutationObserver(schedule);
  mo.observe(document.documentElement, {
    childList: true, subtree: true, characterData: true, attributes: true,
    attributeFilter: ['class', 'style']
  });
  window.addEventListener('resize', schedule);
  window.addEventListener('orientationchange', schedule);
  window.addEventListener('scroll', schedule, true);

  // 轮询兜底：路由切换不会触发统一的 DOM 事件
  setInterval(function () {
    var q = qnum();
    if (q !== lastQ) schedule();
  }, 700);

  setTimeout(measure, 300);
  setTimeout(measure, 1200);
})();
"""#

// MARK: - 原生 ↔ 网页桥
final class InkBridge: NSObject, ObservableObject, WKScriptMessageHandler {

    struct Payload: Decodable {
        struct Box: Decodable {
            let x: Double
            let y: Double
            let w: Double
            let h: Double
        }
        let box: Box?
        let q: String?
        let path: String?
        let host: String?
        let ready: Bool?
    }

    @Published var targetRect: CGRect = .zero
    @Published var questionID: String = ""
    @Published var pageKey: String = ""
    @Published var ready: Bool = false

    weak var webView: WKWebView?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        var box = CGRect.zero
        if let b = body["box"] as? [String: Any],
           let x = b["x"] as? Double, let y = b["y"] as? Double,
           let w = b["w"] as? Double, let h = b["h"] as? Double {
            box = CGRect(x: x, y: y, width: w, height: h)
        }

        let q = (body["q"] as? String) ?? ""
        let host = (body["host"] as? String) ?? ""
        let path = (body["path"] as? String) ?? ""
        let isReady = (body["ready"] as? Bool) ?? false

        DispatchQueue.main.async {
            self.targetRect = box
            self.questionID = q
            self.pageKey = InkStore.makeKey(host: host, path: path, questionID: q.isEmpty ? nil : q)
            self.ready = isReady
        }
    }

    /// 刷新测量（重进页面、切题后调用）
    func refresh() {
        webView?.evaluateJavaScript("window.__inkMeasure && window.__inkMeasure();")
    }
}
