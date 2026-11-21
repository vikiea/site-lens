# 易幕 live.js（直播源脚本）字节码提取结果

- 文件：`https://www.jdbus.net/sources/live.js?v=93235`
- 形式：`QBC1:` + Base64 → **QuickJS 字节码**（266,415 字节，非明文 JS）
- 提取到 295 条播放地址、24 个 CDN 域名

## CDN / 源站分布

- `hlsztemgsplive.miguvideo.com` × 222
- `gslbmgsplive.miguvideo.com` × 19
- `live4-fuyun.fjtv.net` × 6
- `bb-live.wifiwx.com` × 5
- `live1-fuyun.fjtv.net` × 4
- `liveplay8.nbtv.cn` × 4
- `zwebl06.cztv.com` × 4
- `live.hoolo.tv` × 3
- `live1.ptbtv.com` × 3
- `tv.vtibet.cn` × 3
- `zwebl04.cztv.com` × 3
- `nklive.nbs.cn` × 2
- `live1.kxm.xmtv.cn` × 2
- `live2-fuyun.fjtv.net` × 2
- `live3.hoolo.tv` × 2
- `zwebl02.cztv.com` × 2
- `hlsal-ldvt.qing.mgtv.com` × 1
- `hlscdn.liangtv.cn` × 1
- ` feiying.litenews0.cn` × 1
- `9bwaz8y2.gzstv.com` × 1

## 逻辑标识（字节码 atom 表）
```
SUB_URLS
HTTP_TIMEOUT
RESOLVE_TIMEOUT RESOLVE_DEADLINE
PROBE_TIMEOUT
CACHE_MS
DEBUG
KKS_UA
KKS_RE
CH_UA
PAGE
RND_SEQ
QUALITIES
MIGU_QMAP
SELF_POOL
SELF_POOL_KEY
SELF_POOL_URL
SECURE_PLAY
SECURE_EP(SELF_POOL_REFRESH_MS
CATALOG
CH_NAME
CH_NAME_EXTRA
CH_LOGO
GULU_EP
MG_DF_KEYS
MG_TS_KEYS
CH_POOL
GULU_POOL
POOL_SKEY
POOL_TSKEY
POOL_REFRESH_MS
NAME2KEY
YSP_API
YSP_PLAT
YSP_APPVER
YSP_TEA_KEY_HEX
YSP_GKEY_HEX
YSP_XOR
YSP_GXOR
YSP_H264CAP
YSP_CH
```

## 样本地址

- `http://gslbmgsplive.miguvideo.com/migu/kailu/nanjingkj/50/20230719/index.m3u8?msisdn=2025091908013422d2a0f4ed5e4511b896d`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/nanjingkj/50/20230719/index.m3u8?msisdn=20251023080141d50925a1117343ecb53b2`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/nanjingxwzh/50/20230719/index.m3u8?msisdn=202509190801346040f34e796a43e3821`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/nanjingxwzh/50/20230719/index.m3u8?msisdn=20251023080141b90781bc871243ca9cc`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/ntxwzh/51/20250604/index.m3u8?msisdn=202509190801352ef9ff3bad3f4a65b064683f`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/ntxwzh/51/20250604/index.m3u8?msisdn=202510230801432bba200bfb354535b9886f03`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/ntxwzh/51/20250604/index.m3u8?msisdn=202510240800592b66efbec2f342349068cf9b`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxdsqc/51/20250804/index.m3u8?msisdn=20250919080136b45ee433a7cf4d688994f00b`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxdsqc/51/20250804/index.m3u8?msisdn=202510230801444202628b64cc49f4bfb9f6b1`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxdsqc/51/20250804/index.m3u8?msisdn=2025102408005947806826798c44e4b89b7ed8`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxxwzx/51/20250804/index.m3u8?msisdn=20250919080136670d8cf97d464e1f874949e4`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxxwzx/51/20250804/index.m3u8?msisdn=202510230801447f8d4c3a1a3c4ca1bd0de217`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/sxxwzx/51/20250804/index.m3u8?msisdn=202510240800591ee112712ed2473aa0d84b8e`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/wxxwzh/51/20250604/index.m3u8?msisdn=202509190801368edab7fc3daa499fa4e273d7`
- `http://gslbmgsplive.miguvideo.com/migu/kailu/wxxwzh/51/20250604/index.m3u8?msisdn=20251023080144558f016a4098437fa4b5f82b`