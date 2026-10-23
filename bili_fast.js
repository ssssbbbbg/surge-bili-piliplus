// bilibili 网页 -> 立即唤起 PiliPlus
// Surge http-request 脚本：本地伪造极轻页面，不请求 bilibili 服务器
// PiliPlus 源码 lib/utils/app_scheme.dart:
//   bilibili://video/{bvid}?t={秒}   内部 *1000 转毫秒
//   bilibili://video/{bvid}?p={分P}

const m = $request.url.match(/\/video\/(BV[0-9A-Za-z]{10})/);
if (!m) {
  $done({});
} else {
  const BV = m[1];

  const qs = ($request.url.split('?')[1] || '');
  const params = {};
  qs.split('&').forEach(function (kv) {
    const i = kv.indexOf('=');
    if (i > 0) params[kv.slice(0, i)] = kv.slice(i + 1);
  });

  const parts = [];
  if (params.t) parts.push('t=' + params.t);
  if (params.p) parts.push('p=' + params.p);
  const query = parts.length ? '?' + parts.join('&') : '';
  const target = 'bilibili://video/' + BV + query;

  const html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>PiliPlus</title><style>'
    + 'html,body{height:100%;margin:0;background:#0f0f13;color:#fff;'
    + 'font:600 16px -apple-system,sans-serif;display:flex;align-items:center;'
    + 'justify-content:center;flex-direction:column;gap:18px}'
    + 'a{display:inline-block;background:#FB7299;color:#fff;text-decoration:none;'
    + 'padding:14px 28px;border-radius:28px;box-shadow:0 8px 24px rgba(251,114,153,.4)}'
    + '.d{font-size:13px;font-weight:400;color:#8a8a95}'
    + '</style></head><body>'
    + '<div>\u6b63\u5728\u6253\u5f00 PiliPlus\u2026</div>'
    + '<a id="go" href="' + target + '">\u25b6 \u624b\u52a8\u6253\u5f00 ' + BV + '</a>'
    + '<div class="d">\u6ca1\u53cd\u5e94\u5c31\u70b9\u4e0a\u9762\u7684\u6309\u94ae</div>'
    + '<script>location.href=' + JSON.stringify(target) + ';'
    + 'setTimeout(function(){try{location.href=' + JSON.stringify(target)
    + ';}catch(e){}},400);</script></body></html>';

  $done({
    response: {
      status: 200,
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
        'Access-Control-Allow-Origin': '*'
      },
      body: html
    }
  });
}
