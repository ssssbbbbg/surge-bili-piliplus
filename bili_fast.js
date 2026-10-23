// bilibili 网页 -> 唤起 PiliPlus（全屏点击版）
// Surge http-request：本地伪造极轻页面，不请求 bilibili 服务器
// 说明：iOS 16+ 禁止无用户交互的自定义 scheme 跳转，
//       故改为「全屏任意位置可点 + 加载即模拟 a.click() 尝试放行」

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
    + '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
    + '<title>PiliPlus</title><style>'
    + 'html,body{height:100%;margin:0;background:#0f0f13;color:#fff;'
    + 'font:600 16px -apple-system,sans-serif;display:flex;align-items:center;'
    + 'justify-content:center;flex-direction:column;gap:16px;'
    + 'cursor:pointer;-webkit-user-select:none;user-select:none;'
    + '-webkit-tap-highlight-color:transparent}'
    + '.ring{width:96px;height:96px;border-radius:50%;background:#FB7299;'
    + 'display:flex;align-items:center;justify-content:center;'
    + 'font-size:34px;line-height:1;color:#fff;'
    + 'box-shadow:0 0 0 0 rgba(251,114,153,.6);animation:pulse 1.6s infinite}'
    + '@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(251,114,153,.6)}'
    + '70%{box-shadow:0 0 0 26px rgba(251,114,153,0)}'
    + '100%{box-shadow:0 0 0 0 rgba(251,114,153,0)}}'
    + '.t{font-size:17px}.d{font-size:13px;font-weight:400;color:#8a8a95}'
    + '</style></head><body>'
    + '<div class="ring">\u25B6</div>'
    + '<div class="t">\u70B9\u4EFB\u610F\u4F4D\u7F6E\u6253\u5F00 PiliPlus</div>'
    + '<div class="d">' + BV + '</div>'
    + '<a id="go" href="' + target + '" style="display:none">go</a>'
    + '<script>'
    + 'var T=' + JSON.stringify(target) + ';'
    + 'var g=document.getElementById("go"),f=0;'
    + 'function jump(){if(f)return;f=1;'
    + 'try{g.click()}catch(e){}'
    + 'try{location.href=T}catch(e){}}'
    + 'document.body.addEventListener("touchend",jump,false);'
    + 'document.body.addEventListener("click",jump,false);'
    + 'setTimeout(function(){try{g.click()}catch(e){}},120);'
    + 'setTimeout(function(){try{g.click()}catch(e){}},600);'
    + '</script></body></html>';

  $done({
    response: {
      status: 200,
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store'
      },
      body: html
    }
  });
}
