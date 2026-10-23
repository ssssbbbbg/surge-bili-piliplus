// bilibili 网页 -> 自动唤起 PiliPlus
// Surge http-response script
// PiliPlus 源码 lib/utils/app_scheme.dart: routePush / _videoProgress
//   bilibili://video/{bvid}?t={秒}   内部 *1000 转毫秒
//   bilibili://video/{bvid}?p={分P}

const m = $request.url.match(/\/video\/(BV[0-9A-Za-z]{10})/);
if (!m) {
  $done({ body: $response.body });
} else {
  const BV = m[1];

  const qs = $request.url.split('?')[1] || '';
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

  let body = $response.body;
  const inject = [
    '<script>',
    '(function(){',
    '  var T=' + JSON.stringify(target) + ';',
    '  var fired=false;',
    '  function open(){if(fired)return;fired=true;try{window.location.href=T;}catch(e){}}',
    '  function mount(){',
    '    if(!document.body){return setTimeout(mount,200);}',
    '    var b=document.createElement("div");',
    '    b.textContent="\u25B6 PiliPlus \u6253\u5F00";',
    '    b.style.cssText="position:fixed;right:18px;bottom:26px;z-index:2147483647;"',
    '      +"background:#FB7299;color:#fff;padding:12px 20px;border-radius:24px;"',
    '      +"font:600 15px -apple-system,sans-serif;box-shadow:0 6px 18px rgba(0,0,0,.35);cursor:pointer;";',
    '    b.onclick=open;',
    '    document.body.appendChild(b);',
    '    setTimeout(open,800);',
    '  }',
    '  mount();',
    '})();',
    '</script>'
  ].join('');

  body = body.indexOf('</body>') >= 0
    ? body.replace('</body>', inject + '</body>')
    : body + inject;

  $done({ body: body });
}
