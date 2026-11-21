# 参考材料（临时）

**这是临时材料，任务结束后删除。** 见文末「删除方式」。

## 为什么在这里

原机器上的逆向产物在 `/root/work/hypnfq` 与 `/root/work/easyl`，接手环境读不到那个路径。这批文件是从中挑出的**最小可用集**（约 150 KB）：接真适配器需要的接口形状、加密方式、鉴权头、域名池、配置形态。

被刻意排除的：APK 本体、`libapp.so` 反汇编、blutter 对象池（`pp.txt` 3.2 MB）、easyl 明文源码。那些只在逆向阶段有用，接客户端接口用不上。需要时再补。

## huangguo/ —— 黄果短剧（top.ultqd.hypnfq v1.7.0）

| 文件 | 内容 |
|---|---|
| `REPORT.md` | 逆向总报告：签名、Dart AOT 还原、接口清单、鉴权与加密、会员与广告补丁、给原生壳的落地建议 |
| `api_inventory.json` | 365 个端点的结构化清单，按模块分组 |
| `endpoints.txt` | 端点全量平铺 |
| `shell_integration.json` | **接适配器先读这个**：传输层、响应包络、`xfCip` 加密参数、鉴权头与签名键、主备域名、DoH 兜底、会员字段 |

### 关键事实（摘自 shell_integration.json，接适配器前必看）

- 业务接口**只接受 POST**，`Content-Type: application/json`；GET 返回 `code=400 "业务接口只支持 POST"`
- 响应包络固定：`code / isLogin / message / needLogin / data / request_id / timestamp / sign`
- `data` 可能是 Base64 的 AES-128-CBC 密文；`sign` 是 32 位小写 hex
- `xfCip` 的 key/iv 不是硬编码常量，运行时从远端 secret 派生（GitHub raw 80 字节 → 2×32 字节 → 各转 64 位 hex 拼 `_3600`）
- HLS 的 m3u8 索引本身也可能被 AES-128 加密，需先解出分片地址
- 主域名 `api1.huangguoju.com`，备用多个，均有热更能力
- 鉴权：`access_token` / `refresh_token`，签名键 `signKey` 家族，埋点用 `eventSignKey`，两者分离

### 未落地的部分（报告第十节）

- `xfCip` 的线上 key 未端到端验证
- `signKey` 的签名算法只定位到候选键集合，未还原算法
- `device_id` 的生成规则未还原
- 广告补丁未落地

**这三项没落地的事实，会直接影响适配器能不能直连接口。** 如果短时间内攻不下来，镜像站（H5）是更现实的首期路径 —— 它在浏览器里跑通全套鉴权，应用只需观察。

## easyl/ —— 易幕（com.easyl.app）

参考价值在**形态**，不在内容：它把"远端配置 + 每个内容源一段脚本字节码"做成了可热更的架构。

- `report.md` / `report2.md` —— 样本指纹、配置体系、安全机制、权益位掩码、真实后端与接口清单
- `easyl_config_v20.json` —— 服务端下发的完整远端配置（清理版）
- `sources_report.md` —— 23 个内容源脚本的字节码提取汇总
- `live_analysis.md` —— live.js 字节码提取结果（295 条播放地址 / 24 个 CDN）
- `patch_notes.md` —— smali 补丁清单

对我们的意义：ADR-0004 里"适配器内部允许有加密/签名/域名发现，对外只暴露目录与凭证"这条边界，正是在看过 easyl 把 24 个源写成 QuickJS 字节码之后定的 —— **热更能力值得要，但不要连加密方案一起变成配置**。

## 使用注意

- 这些文件是**分析产物**，其中的接口、密钥、域名都是分析当时的状态，可能已经失效。
- 不要把这里的内容当权威事实直接写进代码注释或 ADR；要和实测核对。
- `easyl_config_v20.json` 里可能含服务端下发的配置片段，**不要把它提交进其他仓库或对外分发**。

## 删除方式

任务结束后：

```bash
git rm -r docs/handoff/reference
git commit -m "chore: 移除临时参考材料"
```

分支合并时用 squash，这批文件不会进入 `main` 的历史。
