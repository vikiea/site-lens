# 远程播放默认关闭：凭证到位前，远程地址必须显式放行

**Status**: superseded by [ADR-0009](0009-remote-playback-is-admitted-by-site-credentials.md)

> 凭证已到位（T4）。远程来源的准入门槛改成了站点凭证，`media_access/remoteSourceAllowed`
> 已被删除；本文只作为当时的过渡决定保留。

## Context

ADR-0005 决定直连出口的播放走服务内远程直连，并点名 `NativeMediaSessionService.open()` 的 scheme 白名单要放开到 `http(s)`。放开它是这张工单的第一刀，但白名单本身会同时放开一条**未经鉴权的**读取通道：任何拿到 Dart 侧 channel 的代码都能让原生 ExoPlayer 去请求任意地址。

站点凭证是后续票（ADR-0007）。凭证注入的数据源还没落地时，远程请求会裸奔。

补充：ADR-0005 原计划让远程会话持有「凭证租约」；凭证票未落地前，远程会话既不持有文件租约，也不持有凭证租约。

## Decision

远程来源由一个显式开关决定，默认关闭：

- 判定对象 `NativeMediaSessionRoute` 只描述「这条地址如果放行，属于哪一类会话」，不读任何配置。
- 服务与桥接层各自读取同一个开关 `media_access/remoteSourceAllowed`（字符串 `"true"` 才放行），把它作为 `remoteSourceAllowed` 传给判定对象。
- 开关为假时，`http(s)` 地址保持既有的拒绝（`远程媒体来源未开启`）；`file` 与 `content` 的行为一字不变。
- 候选已有可播放本地文件时，即使请求地址是远程地址，也按本地会话处理——这是 ADR-0002「远程路径按候选是否已有可播放本地文件分流」的下游形状。

## Rejected options

- **白名单无条件放开**：在凭证票落地前，等于把原生播放器变成通用 HTTP 客户端，且没有任何一处可以关掉它。
- **把开关做成 Dart 侧参数**：Dart 侧不能证明调用方是谁；开关留在原生偏好里，桥接层与服务工作在同一个进程边界内。

## Consequences

- 这张票的远程播放是「可验证的管道」，不是「已交付的能力」：功能要到凭证票之后才对用户打开。
- 凭证票只需要把 `remoteSourceEnabled` 的判断从偏好换成凭证检查，判定对象与服务传参不变。
- 设备验收若需要走远程地址，必须显式打开该开关；未打开时失败归因是「远程媒体来源未开启」，不是网络错误。
