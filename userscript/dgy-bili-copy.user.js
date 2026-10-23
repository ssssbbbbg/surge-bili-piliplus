// ==UserScript==
// @name         大观园 · 视频讲解一键复制 B 站链接
// @namespace    dgy.bili.copy
// @version      1.2
// @description  在「视频讲解」弹窗每条视频下方插入「复制 + 跳转」按钮
// @match        *://*.cxyonly.fans/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  var WRAP_CLASS = 'dgy-bili-wrap';
  var BTN_CLASS = 'dgy-bili-copy';

  // 从 a[href="/video/BVxxx/?..."] 拼完整 B 站链接
  function fullBiliUrl(href) {
    if (!href) return null;
    var m = href.match(/\/video\/(BV[0-9A-Za-z]{10})\/?(\?[^#]*)?/);
    if (!m) return null;
    var bv = m[1];
    var qs = m[2] || '';
    var params = {};
    qs.replace(/^\?/, '').split('&').forEach(function (kv) {
      if (!kv) return;
      var i = kv.indexOf('=');
      if (i > 0) params[kv.slice(0, i)] = kv.slice(i + 1);
    });
    var out = [];
    if (params.t) out.push('t=' + params.t);
    if (params.p) out.push('p=' + params.p);
    if (params.start_progress) out.push('start_progress=' + params.start_progress);
    return 'https://www.bilibili.com/video/' + bv + '/' +
           (out.length ? '?' + out.join('&') : '');
  }

  // 由网页链接推导 PiliPlus 可识别的 bilibili:// scheme
  function toScheme(url) {
    var m = url.match(/\/video\/(BV[0-9A-Za-z]{10})\/?(\?.*)?$/);
    if (!m) return null;
    var bv = m[1];
    var qs = m[2] || '';
    var params = {};
    qs.replace(/^\?/, '').split('&').forEach(function (kv) {
      if (!kv) return;
      var i = kv.indexOf('=');
      if (i > 0) params[kv.slice(0, i)] = kv.slice(i + 1);
    });
    var out = [];
    if (params.start_progress) out.push('start_progress=' + params.start_progress);
    else if (params.t) out.push('t=' + params.t);
    if (params.p) out.push('p=' + params.p);
    return 'bilibili://video/' + bv + (out.length ? '?' + out.join('&') : '');
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;top:0;left:-9999px;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, text.length);
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
      ok ? resolve() : reject(new Error('execCommand failed'));
    });
  }

  function reset(btn) {
    btn.textContent = '\u{1F4CB} \u590D\u5236 + \u8DF3\u8F6C';
    btn.style.background = '#FB7299';
    btn.style.color = '#fff';
  }

  function decorate(li) {
    if (li.querySelector('.' + BTN_CLASS)) return;

    var link = li.querySelector('a[href*="/video/BV"]');
    if (!link) return;

    var url = fullBiliUrl(link.getAttribute('href'));
    if (!url) return;

    var scheme = toScheme(url);

    var wrap = document.createElement('div');
    wrap.className = WRAP_CLASS;
    wrap.style.cssText = 'display:flex;gap:8px;margin:8px 0 0;width:100%;';

    // 主按钮：复制 + 跳转
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = BTN_CLASS;
    btn.textContent = '\u{1F4CB} \u590D\u5236 + \u8DF3\u8F6C';
    btn.style.cssText =
      'flex:1;background:#FB7299;color:#fff;border:none;border-radius:8px;' +
      'padding:10px 14px;font-size:13px;font-weight:600;cursor:pointer;' +
      'font-family:-apple-system,sans-serif;';

    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();

      copyText(url).then(function () {
        btn.textContent = '\u2713 \u5DF2\u590D\u5236\uFF0C\u6B63\u5728\u8DF3\u8F6C\u2026';
        btn.style.background = '#2ecc71';

        // 复制成功后立刻扔 scheme
        if (scheme) {
          // 用 iframe 触发，避免顶掉当前页面
          try {
            window.location.href = scheme;
          } catch (err) {
            var f = document.createElement('iframe');
            f.style.display = 'none';
            f.src = scheme;
            document.body.appendChild(f);
            setTimeout(function () { f.remove(); }, 2000);
          }
        }

        setTimeout(function () { reset(btn); }, 2500);
      }).catch(function (err) {
        btn.textContent = '\u2717 \u5931\u8D25: ' + (err && err.message || '');
        setTimeout(function () { reset(btn); }, 2500);
      });
    });

    // 副按钮：只复制（不跳）
    var only = document.createElement('button');
    only.type = 'button';
    only.textContent = '\u53EA\u590D\u5236';
    only.style.cssText =
      'flex:0 0 auto;background:#fff;color:#FB7299;border:1px solid #FB7299;' +
      'border-radius:8px;padding:10px 12px;font-size:13px;font-weight:600;' +
      'cursor:pointer;font-family:-apple-system,sans-serif;';

    only.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      copyText(url).then(function () {
        only.textContent = '\u2713';
        setTimeout(function () { only.textContent = '\u53EA\u590D\u5236'; }, 1500);
      });
    });

    wrap.appendChild(btn);
    wrap.appendChild(only);
    li.appendChild(wrap);
  }

  function scan() {
    var links = document.querySelectorAll('a[href*="/video/BV"]');
    for (var i = 0; i < links.length; i++) {
      var li = links[i].closest('li');
      if (li) decorate(li);
    }
  }

  var pending = null;
  function schedule() {
    if (pending) return;
    pending = setTimeout(function () {
      pending = null;
      scan();
    }, 200);
  }

  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule);
  } else {
    schedule();
  }
})();
