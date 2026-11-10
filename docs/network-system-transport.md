# Android 系统网络传输契约

Read this when changing requests, proxy/PAC handling, DNS, media playback/download, update networking, userscript HTTP, filter refresh, or network lifecycle behavior.

## Ownership

Android app-owned HTTP has one network owner: `SystemMediaNetwork`.

- It reads the active `ProxySelector`/PAC list for the target URL.
- It preserves the order returned by the OS and accepts HTTP, SOCKS, and an explicitly returned DIRECT candidate.
- It never inserts, rotates, reorders, or interprets proxy routes on its own.
- HTTP and SOCKS proxies own origin-name lookup. DIRECT uses system DNS by default.
- Buffered requests and resumable app-owned transfers selected through an
  HTTP/SOCKS proxy use HTTP/1.1 for compatibility with local proxy tunnels;
  DIRECT connections retain OkHttp's normal protocol negotiation.
- A user-selected built-in DoH provider applies to DIRECT lookups. One DoH failure falls back to system DNS inside the same request budget; network changes clear the cache.
- TLS, SNI, hostname verification, non-HTTP(S), and URL userinfo checks remain enforced.
- Loopback, RFC1918, link-local, LAN names, Fake-IP values, and VPN/TUN interfaces are passed to the system connection stack. A real connection failure is the only reason the app reports those targets unreachable.

The same boundary applies to:

- discovery's five-second HTTP candidate budget;
- native media metadata and resumable downloads;
- Media3 manifest/key/segment playback;
- update metadata and APK download;
- GM/userscript HTTP and filter-source refresh;
- background health probes and WorkManager transfers.

WebView traffic remains owned by Chromium. A native probe is never treated as evidence of which route Chromium used.

DLNA discovery, SOAP control, and LAN relay are explicit local-network exceptions.

## Retry and lifecycle

- One HTTP call is one bounded logical request. Dart and Kotlin must not each replay the same failure.
- The OS PAC list is the only proxy fallback list. If the system returns no route, the app reports a system-proxy failure instead of inventing DIRECT.
- Media keeps resource budgets, HTTP Range/ETag/Last-Modified validation, partial files, task identity, progress, and file leases.
- Update downloads keep Range resume and the documented retry/backoff policy.
- WorkManager keeps its durable retry ownership for background media.
- Proxy, VPN, DNS, or default-network link changes are coalesced into one settled native epoch. That epoch clears DNS cache, cancels active network calls, and emits one Dart `networkChanged` event.
- Media recovery starts only from the settled native event. Android `connectivity_plus` events invalidate probe results and DNS but do not start a second media recovery coordinator.
- A native-first media stop is reported as `media_cancelled`; the task remains paused with its partial bytes and is restarted by the same settled event.
- Chromium may publish both `NetworkError` and a committed error-page event for one navigation. NativeHosts presents one normalized failure and performs at most one automatic reload per load generation.

## Secure DNS configuration

- New installs use system DNS (`off`).
- Existing user selections persist in AppSettings and are synchronized to Android SharedPreferences.
- Flutter settings verification, foreground requests, Media3, update Service/Worker, and headless probes read the same native provider selection.
- DoH bootstrap may use system DNS to locate the resolver endpoint. The target name is not resolved locally when an HTTP/SOCKS proxy owns it.

## Security boundaries

Reachability policy is separate from authorization:

- user scripts still require the confirmed `@connect` set;
- update requests still require the fixed GitHub allowlist;
- media requests still require the source-page and task authorization context;
- cache, export, and local-file paths still require canonical-path and file-lease checks;
- bridge and userscript payloads remain untrusted.

## Device acceptance matrix

Record current package identity, network epoch and exact outcome for each row. Do not infer one row from another.

| Case | Required observation |
| --- | --- |
| Clash/other local HTTP proxy `127.0.0.1:7890` | probe, WebView, Media3 and download all connect through the system proxy |
| PAC HTTP then DIRECT | the request follows the OS order; app logs show no invented candidate |
| PAC SOCKS | target request succeeds or reports the actual SOCKS transport failure |
| OpenClash/router Fake-IP | DNS result reaches connection; no app-level `fake_ip_policy` rejection |
| DNS returns `127.0.0.1` | app attempts the connection; refusal and success are reported as actual results |
| LAN/private HTTP(S) target | reachable target works; unreachable target reports connection failure |
| Secure DNS success | selected DoH resolves DIRECT traffic |
| Secure DNS failure | exactly one system-DNS fallback succeeds within the request budget |
| Proxy disabled | active calls fail or succeed without stale ProxySelector/DNS reuse |
| Wi-Fi/cellular/VPN switch | active calls cancel, DNS cache clears, partial media resumes |
| Background media | WorkManager resumes an unpaused task after network change |
| Media3 HLS | manifest, key and segments use the same system policy |
| WebView failure | duplicate browser error events produce one user-visible error/retry |
| DLNA | SSDP, SOAP and local relay still use explicit LAN-direct behavior |

## Validation gates

1. `make check`
2. Android unit tests, including `SystemMediaNetworkTest`, `HealthHttpProbeTest`, and `ResumableMediaTransferTest`
3. `python3 tool/verify_level.py --auto`
4. L2/L3 device evidence for the matrix above
5. independent read-only review with `APPROVE`
6. version/tag only after review
7. formal APK identity, GitHub Verify, Release, checksum and device acceptance recorded separately
