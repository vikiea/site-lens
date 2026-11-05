import json

# renderer constants
ROW_TOP = [128, 242, 356, 470, 584]
H = 58
stage_cx = lambda s: 100 + 215 * s
stage_l = lambda s: stage_cx(s) - 84
stage_r = lambda s: stage_cx(s) + 84

NODES = [
    # id, stage, row, width, label, sublabel, tag, sources
    ("page_script", 0, 1, 150, "页面脚本嗅探", "页面脚本", "resource timing",
     [("web_assets/media_lifecycle.js", 57, "post(kind, fields)"),
      ("web_assets/media_lifecycle.js", 1175, "post('candidates')")]),
    ("authorize", 1, 0, 120, "授权与校验", "会话凭据与世代", "authorize",
     [("lib/web_host/native_hosts.dart", 271, "authorizeMediaCandidate"),
      ("lib/media/media_service.dart", 442, "MediaCandidateValidator")]),
    ("task_row", 1, 2, 132, "MediaTask 行", "任务状态与进度", "MediaTaskStore",
     [("lib/media/media_service.dart", 533, "MediaTaskStore"),
      ("lib/media/media_service.dart", 1173, "_transition")]),
    ("native", 2, 0, 150, "原生 Worker 传输", "6 分钟切片", "WorkManager",
     [("android/app/src/main/kotlin/dev/vikiea/site_lens/NativeMediaDownloadWorker.kt", 29, "doWork"),
      ("android/app/src/main/kotlin/dev/vikiea/site_lens/NativeDownloadRuntime.kt", 99, "start")]),
    ("dart", 2, 2, 132, "Dart HLS 传输", "清单与分片", "_startHls",
     [("lib/media/media_service.dart", 2949, "_startHls"),
      ("lib/media/media_service.dart", 2852, "start")]),
    ("partial", 3, 0, 150, ".part + .resume", "校验与续传", "断点续传",
     [("android/app/src/main/kotlin/dev/vikiea/site_lens/ResumableMediaTransfer.kt", 56, "transfer"),
      ("android/app/src/main/kotlin/dev/vikiea/site_lens/ResumableMediaTransfer.kt", 294, "MediaAuthorizationException")]),
    ("media_file", 3, 2, 150, ".media 成品", "原子改名", "localRef",
     [("lib/media/media_service.dart", 2852, "start"),
      ("lib/media/media_service.dart", 1277, "setLocalRef")]),
    ("consume", 4, 0, 140, "播放 / 投屏", "Media3 · DLNA", "消费产物",
     [("android/app/src/main/kotlin/dev/vikiea/site_lens/NativeMediaSessionService.kt", 416, "open"),
      ("lib/media/dlna_service.dart", 862, "cast")]),
    ("export", 4, 2, 140, "导出 MP4", "MediaExportQueue", "独立所有权",
     [("lib/media/media_export_queue.dart", 233, "enqueueAutomatic"),
      ("lib/media/media_library.dart", 1286, "deliver")]),
]

N = {}
for nid, st, row, w, label, sub, tag, srcs in NODES:
    y = ROW_TOP[row]
    cx = stage_cx(st)
    N[nid] = dict(stage=st, row=row, w=w, x=cx - w / 2, y=y, cx=cx, cy=y + H / 2,
                  top=y, bottom=y + H, left=cx - w / 2, right=cx + w / 2, label=label)


def pt(nid, side):
    n = N[nid]
    return {"left": [n["left"], n["cy"]], "right": [n["right"], n["cy"]],
            "top": [n["cx"], n["top"]], "bottom": [n["cx"], n["bottom"]]}[side]


SX = {s: stage_cx(s) for s in range(5)}
# vertical corridor x limits: stage frames [16,184] [231,399] [446,614] [661,829] [876,1044]
GAP = {
    0: (196, 222),   # between stage 0 and 1
    1: (411, 437),
    2: (626, 652),
    3: (841, 867),
}

FLOWS = []
DIAG = []


def flow(fid, src, fside, dst, tside, label, via, lat, variant=None, cls=None):
    pts = [pt(src, fside)] + via + [pt(dst, tside)]
    d = {"id": fid, "from": src, "to": dst, "label": label, "fromSide": fside, "toSide": tside,
         "via": via}
    if lat:
        d["labelAt"] = lat
    if variant:
        d["variant"] = variant
    if cls:
        d["classification"] = cls
    FLOWS.append(d)
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        if abs(a[0] - b[0]) > 0.01 and abs(a[1] - b[1]) > 0.01:
            DIAG.append(f"{fid} diagonal {a}->{b}")
        if abs(a[0] - b[0]) + abs(a[1] - b[1]) < 0.01:
            DIAG.append(f"{fid} zero segment {a}")


# x of corridor axes
A = GAP[0][0] + 6      # 202
B = GAP[1][0] + 6      # 417
C = GAP[2][0] + 6      # 632
D = GAP[3][0] + 6      # 847

# --- stage 0 -> stage 1 (corridor A)
flow("f1", "page_script", "right", "authorize", "left", "MediaCandidateDto",
     [[A, 271], [A, 157]], [A, 110], "emphasis", "策略 HTTP")
flow("f2", "page_script", "right", "task_row", "left", "MediaCandidateDto",
     [[A + 12, 271], [A + 12, 385]], [A + 12, 330], "emphasis", "策略 HTTP")
# --- stage 1 internals
flow("f3", "authorize", "bottom", "task_row", "top", "授权通过",
     [], [315, 262], "security", "会话凭据")
# --- stage 1 -> stage 2 (corridor B)
flow("f4", "authorize", "right", "native", "left", "直链 / 无自定义头",
     [[B, 157]], [B - 3, 110], "emphasis", "原生路径")
flow("f5", "task_row", "right", "dart", "left", "HLS / 自定义请求头",
     [[B, 385]], [B - 14, 322], None, "Dart 路径")
# --- stage 2 -> stage 3 (corridor C)
flow("f6", "native", "right", "partial", "top", "进度 / 字节",
     [[C, 157], [C, 112], [745, 112]], [C + 20, 112], "emphasis", "原生传输")
flow("f7", "dart", "right", "partial", "left", "分片落盘",
     [[C, 385], [C, 157]], [C, 300], "emphasis", "_startHls")
# --- stage 3 internals
flow("f8", "partial", "bottom", "media_file", "top", "原子改名",
     [], [745, 328], "emphasis", "落盘")
# --- stage 3 -> stage 4 (corridor D)
flow("f9", "media_file", "right", "consume", "left", "localRef / MediaArtifact",
     [[D, 385], [D, 157]], [D, 262], "emphasis", "媒体库")
flow("f10", "media_file", "right", "export", "left", "MP4 导出",
     [], [955, 440], None, "MediaExportQueue")

nodes_json = []
for nid, st, row, w, label, sub, tag, srcs in NODES:
    nodes_json.append({
        "id": nid, "type": "frontend" if nid in ("page_script", "consume") else
        ("security" if nid == "authorize" else ("database" if nid in ("partial", "media_file") else "backend")),
        "label": label, "sublabel": sub, "tag": tag,
        "stage": st, "row": row, "width": w,
        "sources": [{"path": p, "line": l, "label": lb} for (p, l, lb) in srcs],
    })

cand = {
    "schema_version": 1,
    "diagram_type": "dataflow",
    "meta": {
        "title": "媒体获取数据流：候选、授权、传输、索引与消费",
        "subtitle": "页面候选经授权校验生成 MediaTask 行，原生 Worker 或 Dart HLS 传输落盘为 .part/.resume 与 .media，再登记媒体库供播放、投屏与导出",
        "locale": "zh-CN",
        "output": ".archify/dataflow-media-acquisition-20261104-200028/media-acquisition.html",
        "quality_profile": "showcase",
        "visual_preset": "signal-flow",
        "repository": {
            "url": "git@github.com:vikiea/site-lens.git",
            "revision": "bc5248d2e480f6f38871a935b2b99c7a5a2c3c21",
            "provider": "github",
            "link_mode": "local-only",
        },
                "viewBox": [1068, 688],
        "legend": {"mode": "all", "entries": {
            "default": {"label": "数据流转"},
            "emphasis": {"label": "主链路"},
            "security": {"label": "授权校验"},
            "dashed": {"label": "分支与异常"},
            "database": {"label": "落盘资产"},
        }},
            },
    "stages": [{"label": lb} for lb in ["发现", "授权与校验", "调度与传输", "落盘与索引", "使用与清理"]],
    "nodes": nodes_json,
    "flows": FLOWS,
    "cards": [
        {"dot": "amber", "title": "授权凭据边界", "items": [
            "页面 Cookie 只留在 CookieManager 与页面会话内。",
            "刷新服务只回传状态、来源与摘要，Cookie 不过 Dart 通道。",
            "带签名 query 的媒体地址无法刷新，直接回到需要重新授权。",
        ]},
        {"dot": "rose", "title": "失败清理只清理失败任务", "items": [
            "批量删除只对 failed 任务生效，其余状态需先停止占用。",
            "清理任务行不影响已导出的 MP4 与媒体库索引。",
            "缓存缺失把 completed/playable 降级为 failed(cacheMissing)。",
        ]},
        {"dot": "violet", "title": "导出与缓存所有权独立", "items": [
            "HLS 缓存目录与导出的 MP4 文件各自持有文件租约。",
            "任务行消失后导出索引仍然保留。",
            "移动文件保留目录 ID，旧路径出现新文件会分配新 ID。",
        ]},
        {"dot": "emerald", "title": "按源身份去重", "items": [
            "重扫用源身份键去重，content:// 取 document 段。",
            "file:// 按归一化路径匹配已有产物。",
            "候选展示去重保留剧集、画质与音轨参数。",
        ]},
    ],
}

with open("/Users/qinfuling/www/github/vikiea/site-lens/.archify/dataflow-media-acquisition-20261104-200028/candidate.json", "w") as fh:
    json.dump(cand, fh, ensure_ascii=False, indent=2)

for nid, n in N.items():
    print(f"{nid:12s} s{n['stage']} r{n['row']} x {n['left']:.0f}-{n['right']:.0f} y {n['top']}-{n['bottom']}")
print("self-check:", DIAG or "clean")
