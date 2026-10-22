# Media3, HCPP and passive device diagnostics

## Dependency baseline (2026-10-21)

Current versions are the resolved lockfile and Gradle runtime graph, not the lower bounds in a version constraint. Latest means stable upstream at the audit date. Flutter remains at the project's verified revision; its newest stable patch was not independently established.

| Direct Dart dependency | Purpose | Before | Selected |
| --- | --- | --- | --- |
| flutter_riverpod | State management | 3.4.3 | 3.4.3 |
| drift | Relational SQLite persistence | 2.35.2 | 2.35.2 |
| sqlite3 | SQLite FFI and native assets | 3.7.1 | 3.7.1 |
| path | File path operations | 1.9.1 | 1.9.1 |
| path_provider | Platform application directories | 2.1.6 | 2.1.6 |
| file_picker | Native document selection | 13.1.0 | 13.1.0 |
| connectivity_plus | Passive network transport class | 7.3.2 | 7.3.2 |
| crypto | Hashes and message authentication | 3.0.7 | 3.0.7 |
| archive | Backup/package ZIPs | 4.5.2 | 4.5.2 |
| workmanager | Deferred health checks | 0.10.10 | 0.10.10 |
| liquid_glass_widgets | Shared glass surfaces | 1.13.0 | 1.14.0 (exact pin) |
| package_info_plus | Installed application identity | 10.2.2 | 10.2.2 |
| url_launcher | External URL opening | 6.3.3 | 6.3.3 |
| http | HTTP transport | 1.6.0 | 1.6.0 |
| re_editor | Userscript editor | 0.10.0 | 0.10.0 |
| re_highlight | Syntax highlighting | 0.0.3 | 0.0.3 |
| flutter_secure_storage | Optional GitHub token | 10.3.4 | 11.2.0 |
| flutter_lints (dev) | Static checks | 6.0.0 | 6.0.0 |
| pigeon (dev) | Typed host bindings | 29.0.10 | 29.0.11 |

All selected direct package versions matched the stable publisher API at the audit. Flutter, flutter_test and integration_test follow Flutter 3.47.6 / Dart 3.13.5; their lockfile `0.0.0` is not an SDK release number.

The compatible transitive update resolves analyzer 14.6.0, _fe_analyzer_shared 110.0.0, android_file_picker 2.1.1, code_builder 4.13.0, dart_style 3.1.14, file_picker_darwin 2.3.2, file_picker_platform_interface 4.2.0, file_picker_web 4.2.0, vector_math 2.4.3 and vm_service 15.4.0. No dependency overrides are introduced. cross_file 0.4.0, material_color_utilities 0.13.1 and test_api 0.7.15 remain constrained by upstream/SDK. re_editor still requires isolate_manager 4.1.5+1 and discontinued isolate_contactor 4.1.0; their latest releases cannot be substituted independently.

| Android dependency/tool | Before | Selected | Newest stable at audit |
| --- | --- | --- | --- |
| Core KTX | declared 1.16.0, resolved 1.18.0 | 1.18.0 | 1.19.1 (compileSdk 37 required) |
| Work runtime | 2.11.2 | 2.12.0 | 2.12.0 |
| WebKit | 1.17.1 | 1.17.1 | 1.17.1; 1.18.0-rc01 excluded |
| SwipeRefreshLayout | 1.1.0 | 1.2.0 | 1.2.0 |
| Media3 ExoPlayer/HLS/Muxer | 1.11.1 | 1.11.1 | 1.11.1 |
| Media3 Inspector / Inspector Frame / Transformer | absent | 1.11.1 | 1.11.1 |
| JUnit | 4.13.2 | 4.13.2 | 4.13.2 |
| AGP | 9.1.0 | 9.1.0 | 9.4.1 |
| Gradle | 9.3.1 | 9.3.1 | 9.8.2 |
| KGP compiler classpath | 2.4.0 | 2.4.0 | 2.4.21 |

AGP 9.1 / Gradle 9.3.1 / KGP 2.4.0 remain one compatible baseline. `android.builtInKotlin=true` is explicit; `android.newDsl=false` remains required by the pinned Flutter Gradle plugin. The `apply false` KGP declaration retains the compiler version but does not apply the legacy Android plugin to the app. Android min/compile/target remain 26/36/36; NDK 28.2.13676358, CMake 3.22.1, build JDK 21 and JVM target 17 remain the baseline.

Expected upstream warnings are the temporary legacy DSL, Flutter/plugin legacy DSL calls and workmanager_android 0.10.9 Groovy assignment syntax. Flutter's textual plugin scanner sees WorkManager's conditional KGP declaration even when built-in Kotlin is active. Do not edit the pub cache or disable warnings globally.

GitHub token storage keeps the existing key, default namespace and RSA OAEP/AES GCM algorithms. Algorithm migration uses backup protection and `resetOnError=false`; a failed keystore read preserves encrypted data and allows retry. Unit channel tests prove the app requests these policies and never deletes on read failure. An actual 10.3.4-to-11.2.0 installed-app upgrade remains a device acceptance case.

## Media processing and ownership

Playback continues through Media3 ExoPlayer with the existing credentials, texture output and lifecycle rules. Metadata uses Inspector MetadataRetriever, thumbnails use FrameExtractor, and encoded samples use MediaExtractorCompat. Inspection restricts data sources to the selected app file or authorized SAF document. Codec/thumbnail failures preserve readable file facts.

HLS export runs strict preflight over every locally prepared segment, then sends one normalized local media playlist to Transformer. The DataSource allowlist includes only those canonical segment/key/init paths and the generated playlist. There is no HTTP fallback or encoder factory capable of producing encoded data. Transformer uses DefaultMuxer, backed by InAppMp4Muxer. ExportResult must report transmuxed video and transmuxed audio (or NA when no audio exists).

The application still owns the input sandbox, supported-encryption policy, track configuration consistency, missing/partial audio rejection, keyframe starts, sample counts, decode-order PTS comparison, raw AAC validation, cancellation, atomic output and SAF delivery. B-frame PTS must not be sorted. Media3 already strips ADTS and emits single raw AAC access units; the old ADTS splitting/clock is not applied to Compat output.

TS preflight shares a no-offset TimestampAdjuster across segments, including 33-bit rollover, and preserves the source's common audio/video clock. A timestamp reset fails explicitly. Video parameter-set identities normalize three/four-byte Annex-B prefixes while preserving SPS/PPS/VPS payloads; AAC ASC and access-unit sizes remain exact. MP4 validation independently checks bounded tables, sample counts, chunk coverage, mdat extents, timing counts and duration. Parser and data-source exceptions are latched before Inspector can turn them into apparent EOF.

A native export owns a HandlerThread/Looper. Start, callbacks and cancellation run on that Looper. `Transformer.cancel()` suppresses normal completion callbacks: its return is explicitly used as the native release barrier before completing the channel request. Dart awaits that request before deleting temporary output or releasing the cache lease. Input validation and final Inspector validation also hold the lease. HLS tasks and exported MP4 catalog entries retain independent ownership and persistent identity.

The synthetic parity archive has 5 four-second fixtures: H.264 TS, H.264 fragmented MP4, AES-128 variants of each, and HEVC TS; every fixture has 48 video samples with B frames and 189 stereo 48 kHz AAC samples. The archive includes per-resource SHA-256 and ffprobe sample/PTS manifests. Recreate with `python3 tool/generate_media3_fixtures.py` (FFmpeg/OpenSSL are developer tools, not app dependencies). `integration_test/media3_parity_test.dart` checks actual exported sample counts/PTS, ADTS absence, config, metadata/thumbnail, complete playback/seek and path/network/discontinuity rejection. It is registered in the combined acceptance suite.

## HCPP and glass

The application Manifest opts into HCPP. Flutter's engine checks API 34+, Impeller Vulkan and SurfaceControl at runtime. API level and a Vulkan feature declaration alone are not proof that HCPP is active. The service uses HybridAndroidViewController.checkIfSupported; missing/failed queries retain the legacy composition fence.

With effective HCPP, Flutter-owned panel/chrome surfaces regain the configured standard/premium shader path while controls directly over a native WebView retain their dedicated polarity backer and fill. Without HCPP, a mounted Android WebView keeps the existing route compatibility fence. Native WebView/video pixels remain outside Flutter shader sampling; no frame-capture bridge is added. Transparency 0/55/100, dark/light, high quality coverage and one-row navigation remain governed by the shared surface system.

## Passive diagnostics contract

Settings opens a typed Pigeon snapshot and lazy codec inventory. Supported/unsupported/unknown/not-applicable/error, application configuration, effective state, observation time and source are distinct. Refresh occurs on page entry, manual refresh and resume. Dynamic facts are fresh; historical media/cast observations keep the producer's timestamp and identity. Native session history is bounded to 32 sessions and is not persisted.

Queries read the merged Manifest/grants, notification channels, installation permission, SAF persisted grant ledger, power/idle/background restrictions, existing WorkManager records, active network transport, existing multicast-lock state and WebView capability predicates. Codec inventory reads system descriptions without creating codecs. The actual browser and diagnostics share one WebView feature evaluator. A SAF grant match does not prove current provider writability; Wi-Fi does not prove receiver reachability.

Reading/refreshing never creates a WebView/player/profile, requests permission, navigates, scans SSDP/DLNA, starts a relay, writes a file or enqueues/cancels work. iOS reports the application's native media/download/export path as unsupported, Android HCPP/SAF as not applicable, and passive local-network authorization as unknown. It reads existing ProcessInfo/notification state and does not start battery monitoring.

Special installation access has its own row and is excluded from ordinary permission counts. Permissions introduced after the device API show as not applicable rather than denied. WorkManager query failure, an empty schedule and unfinished work have separate results. Reading power/idle fields does not prove a background policy is effective. iOS exposes the codec boundary without an inventory action.

## Validation boundaries

Run `make check`, Android native unit tests and `make build` before review. `python3 tool/verify_level.py --auto` classifies this cross-layer/build change at L4; local signed-APK verification does not satisfy L3 device acceptance by itself. Use the canonical acceptance runner for database backup/restore and record real device/emulator type. Published release/CI and manual device acceptance are separate evidence states.

Required runtime matrix includes API below 34, API 34+ with usable Vulkan, API 34+ automatic compatibility, browser/video overlays, transparent/dark/light glass, permission denial, expired SAF grants, background restrictions, codec inventory and Token upgrade preservation. The current workstation emulator reached API 37 boot-complete but was stopped when host swap free dropped below the validation skill's 1 GiB boundary; this proves emulator startup only, not media/HCPP acceptance.

Sources: Android Media3 Inspector, Media3 Transformer supported formats and Media3 1.11.1 source; Flutter platform-views and built-in Kotlin migration; AndroidX release pages; pub.dev publisher APIs. Dependency updates should rerun the snapshot rather than assuming this audit remains current.


## HLS timeline and episode regression validation (2026-10-22)

The Media3 1.11.1 adapter preserves complete TS PES output at segment EOF,
normalizes only whole-timeline fMP4 edit-list translations, and restores the first
video PTS when the Transformer mux wrapper zeroes that sample while retaining
leading audio. The official readers, Transformer and application muxer still
own encoded samples and MP4 writing. Unsupported clipping edits and arithmetic
overflow fail before an output is accepted.

Candidate discovery retains a confirmed explicit playlist during same-series SPA
episode navigation. A new series must establish matching page data; old visits,
out-of-order responses and recommendation owners cannot bind media to it.
Recommendation identities remain bounded across DOM removal so Resource Timing
does not reintroduce a known foreign stream. A timing-only URL reused by several
series can be conservatively omitted rather than assigned an invented episode.

Completed checks for this revision:

- `make check`: 523 Flutter tests, analyzer and JS/Python contracts passed.
- `./gradlew :app:testDebugUnitTest`: passed, including timestamp, complete edit
  list, overflow and WebView media-feature combinations.
- `python3 tool/verify_level.py --level L4 --device DEVICE`: passed on Android 16
  / WebView 155, including 30 combined integration cases, database SHA-256
  restoration, formal package identity and fixed signing-certificate validation.
- Five H.264/H.265, TS/fMP4, AES-128 fixtures preserved AAC counts, B-frame PTS,
  EOS, metadata/thumbnails and playback/seek behavior.
- A real-page test with locally supplied URL and expected episode numbers
  confirmed only explicitly mapped episodes were shown. No private test URL is
  stored in source or the formal APK.

The optional system-proxy fixture requires `SITE_LENS_PROXY_FIXTURE=true` and a
separately prepared local proxy. Ordinary acceptance never changes system proxy
settings and does not assume that a user's proxy serves the fixture domain.
Passive diagnostics share the same three WebView media-feature predicates as
BrowserMediaController, reporting missing capabilities separately from query
failure or an actual playback observation.
