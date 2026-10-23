# BiliToPili — Surge 模块

bilibili 网页视频链接 → 自动唤起 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 打开。

## 为什么需要它

PiliPlus 在 iOS 上注册的 universal link 域名（`www.bilibili.com` 等）和 bilibili 官方 app 完全重叠，iOS 只认官方那个。所以 Safari 里点 bilibili 链接永远不会进 PiliPlus。

本模块绕过 universal link：由 Surge 往页面注入一段 JS，主动把 `bilibili://video/BV...` 交给系统。没装官方 app 时，`bilibili://` 只有 PiliPlus 一个处理者，直接跳。

## 安装

Surge → 首页 → 模块 → 「+」→ 从 URL 安装：

```
https://raw.githubusercontent.com/ssssbbbbg/surge-bili-piliplus/main/BiliToPili.sgmodule
```

## 必做两步

1. Surge → 设置 → MITM → 确认 `www.bilibili.com`、`m.bilibili.com` 在列表
2. iOS 设置 → 通用 → 关于本机 → 证书信任设置 → 打开 Surge root 证书开关

装证书 ≠ 信任证书。漏了第二步脚本完全不执行。

## 行为

- 打开 `https://www.bilibili.com/video/BVxxxxxxxxxx` 页面
- 右下角出现粉色「▶ PiliPlus 打开」按钮
- 800ms 后自动尝试唤起；Safari 拦截无交互跳转时点按钮即可
- 保留 `?t=` 秒数进度（PiliPlus 内部 ×1000 转毫秒，落在同一帧）
- 保留 `?p=` 分P

## 不覆盖

- `b23.tv` 短链（未解跳），PiliPlus 内粘贴能自己识别
- `bangumi/play` 番剧页未做映射（PiliPlus 支持，需要可加 pattern）

## 排障

| 症状 | 原因 | 修 |
|---|---|---|
| 右下角没按钮 | 脚本没跑 | MITM 未生效 / 证书未信任 / 模块未开 |
| 按钮在但自动不弹 | Safari 拦无交互跳转 | 正常，点按钮 |
| 弹「打开?」点了没反应 | scheme 注册缓存脏 | 整机重启，先手动开一次 PiliPlus |
| 跳去官方 app | 官方也在抢 `bilibili://` | 卸官方 app，或弹窗选 PiliPlus |

## License

MIT
