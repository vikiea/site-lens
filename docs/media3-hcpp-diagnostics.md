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

The application Manifest opts into HCPP. Flutter's engine checks API 34+, Impeller Vulkan and SurfaceControl at runtime. API level and a Vulkan feature declaration alone are not proof that HCPP is active. The service uses HybridAndroidViewController.checkIfSupported; missing/failed queries remain diagnostic facts and do not trigger a device-model-based global Impeller downgrade.

Flutter-owned panel/chrome surfaces use the configured standard/premium shader path whenever the selected Flutter renderer supports it. Controls directly over a native WebView retain their dedicated polarity backer and fill regardless of HCPP, because native WebView/video pixels remain outside Flutter shader sampling; no frame-capture bridge is added. HCPP remains a diagnostic capability and an input to platform-view composition decisions, while the optional `siteLensForceSkia=true` build is the explicit compatibility escape hatch. Transparency 0/55/100, dark/light, high quality coverage and one-row navigation remain governed by the shared surface system.

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
- Five H.264/H.265, TS/fMP4, AES-128 fixtures preserved AAC counts, B-frame PTS
  and EOS. At this earlier revision, actual thumbnail/playback/seek checks ran
  only for H.264 TS; the expanded per-fixture checks are recorded below.
- A real-page test with locally supplied URL and expected episode numbers
  confirmed only explicitly mapped episodes were shown. No private test URL is
  stored in source or the formal APK.

The optional system-proxy fixture requires `SITE_LENS_PROXY_FIXTURE=true` and a
separately prepared local proxy. Ordinary acceptance never changes system proxy
settings and does not assume that a user's proxy serves the fixture domain.
Passive diagnostics share the same three WebView media-feature predicates as
BrowserMediaController, reporting missing capabilities separately from query
failure or an actual playback observation.

## Proxy safety and thumbnail regression checks (2026-10-22)

The explicit proxy fixture now uses `tool/run_android_proxy_acceptance.py` and
`tool/android_proxy_lease.py`. Ordinary acceptance does not change proxy
settings. An existing user HTTP/PAC proxy prevents takeover. The fixture
forwards ordinary HTTP and verified HTTPS CONNECT without decrypting TLS or
logging unrelated destinations. A device-side heartbeat watchdog attempts
rollback after missed heartbeats, host-process death or the 180-second lease
deadline. Failed Settings writes are retried; the deadline triggers rollback
and does not guarantee restoration completes within 180 seconds. Restoration
resets Android's running proxy before restoring the saved fields. During cleanup,
a live host keeps the relay available while ownership cannot be verified.
The strict acceptance runner also offers `--no-adb-recovery` for an endpoint
whose single allowed recovery has already been used.

The explicit physical-device proxy run passed actual discovery redirect,
playlist and segment-byte checks, ordinary HTTP/HTTPS forwarding, host-process
termination rollback, all-field restoration and subsequent system Internet
checks. This is separate from the intentionally skipped proxy case in ordinary
acceptance. Backup failures now stop before tests or restore installation;
only explicit file-existence responses count as a complete backup.

Both media lists use `MediaThumbnail`: a stable bounded slot with a loose,
centered image, `BoxFit.contain` and a clip following the image's actual size.
Android's generated JPEG no longer stretches every frame to 320x180. It keeps
the decoded frame ratio within those bounds and does not enlarge small frames.
The `v2` cache namespace avoids reusing previously distorted JPEGs; successful
metadata inspection updates the catalog to the new thumbnail. Old files are
not eagerly deleted, and failed optional extraction may retain an earlier
catalog preview until a later successful inspection.

Completed checks:

- L1 full local check passed: 551 Flutter tests, analyzer and JS/Python
  contracts. The later list-only test-define regression passed all 36 Android
  tooling tests; thumbnail/evidence targeted tests passed all 17 cases.
- `./gradlew :app:testDebugUnitTest` passed, including eight thumbnail geometry
  regressions for landscape, portrait, square, non-16:9, panorama, small and
  extreme inputs.
- Physical Android 16 acceptance passed all 31 cases, followed by normal debug
  installation and verified database restoration. A new case mounts both media
  lists: the local-file phase makes no network request, while the network phase
  fetches the controlled thumbnail URL. Each decodes the 160x96 source frame
  and renders it at 68x40.8; neither generation nor display stretches it.
- All five Media3 fixtures now independently check nonempty thumbnail output,
  playback to at least 3800 ms, seek to 1800 ms and continued decoding after seek, in
  addition to sample/AAC/timing and sandbox contracts.

The first run containing the new UI case failed because its scroll helper
matched multiple scrollables. It remains a failed batch; the subsequent 31-case
run uses the explicitly selected list viewport. A separate earlier 30-case run
had an installation restriction during restoration and required a successful
restore-only operation; test assertions alone did not establish its recovery.

Real-site acceptance now checks each exposed episode-to-resource binding, not
only episode counts, and optional download selects the page's current episode.
Multiline page lists are base64-encoded for Flutter CLI and can be supplied
without a separate single URL. The latest eight-page device attempt stopped
at page loading: the device resolved that test domain to 0.0.0.0 and a system
curl request also failed, while independent HTTPS checks returned 204 and 200.
No DNS, VPN or network-profile policy was changed during that earlier attempt.
Eight-page mapping, actual story content, real-site download and cross-episode
SPA behavior remained unverified by that attempt; the later targeted evidence
below supersedes only the current page's loading and complete-download boundary.
Private test URLs are not stored in source
or normal product builds.

The local WebView identity fixture now exercises eight mapped episodes, a
same-count second series with different per-episode URLs, a same-series DOM
revision, a page-owned episode response and a repeated-resource ambiguous
mapping. It compares complete URLs including selection parameters. Its current
device run passed the eight-episode SPA contract before the restore-install
permission failure; restore-only then succeeded and verified the database.

The lifecycle implementation also rejects three deterministic stale-identity
cases: changing only a retired node's text or episode label, letting a later
explicit map remain overridden by an older episode response, and sending
next/previous to a recommendation or ambiguous player. Nine VM regressions plus
the existing lifecycle suite pass. MediaSession next/previous acceptance was
extended with one current-series player and one foreign player whose URLs share
an episode identity; the scoped action driver only sends commands to the
debug package's uniquely identified session.

The stale-resource guard is per normalized media URL. Removing an unrelated
`data-*` attribute or rotating only a retired player's authorization token does
not reopen the old URL; a genuinely new media URL may be observed. These cases
including fragment changes have dedicated VM coverage. The real-device background-control extension now
requires the foreign player to be demonstrably playing before issuing the
system command, then checks its full URL, ready state and playing state after
the current-series switch. The later protected Android 16 batch passed the
eight-episode identity case, all five fixture playback/seek checks and the
thumbnail case, but finished 30/31 because notification stop was not visible.
Removing duplicate custom skip actions exposed stop; the final scoped driver
also waits for the debug session to disappear before collapsing the notification
shade. Next/previous, pause/resume, notification stop and final page state then
passed in a targeted run. Its normal-package restore was denied and the device
went offline before restore-only could complete. The suite assertions and the
incomplete recovery remain separate facts; the full batch is not 31/31.

The checkout first incorporated `2993e08` (alpha9), then `a28ce05` (alpha10's
always-visible settings categories). Current priorities and evidence validity are in
[active-work-plan.md](active-work-plan.md). The later device is a different
Android phone and must not receive the earlier phone's database backup.

On that API 34 / WebView 155 phone, the full protected batch reported 31 successes
and one failure: exact floating-point equality of the network thumbnail's center.
The file thumbnail, current-series next/previous, pause/resume/stop, actual HCPP,
independent export retention and all five Media3 parity/playback/seek fixtures
passed. The normal product package and this phone's own database were restored.
The batch retains its original FAIL result. Changing only the center assertion
to a distance below 0.01 logical pixels made the targeted thumbnail case pass for
both file and network images; aspect ratio, bounds, decoded frame and source
checks remain. That targeted run also completed product/data restoration.

DOM candidate event completion now awaits its SQLite write. A held-write
regression proves that awaiting the event no longer leaves a detached database
transaction to race task creation or database closure. The original cross-frame
authorization test remains enabled; it passed in the final local check. Candidate
publication now remains pending until the write succeeds, and clear, host
invalidation and destruction drain in-flight publication barriers. A failed
write is recorded and cannot produce an in-memory authorizable candidate.
The same publication barrier covers `registerMedia`; after persistence it checks
revoked/disposed/generation, so a route-clear cannot resurrect an in-flight
script registration. A held-write + clear regression and independent review
cover this case.

## Real-page network diagnosis and download (2026-10-22)

The API 34 / WebView 155 device separately completed the premium-glass codec
inventory case: 85 native entries, no compatibility fallback, end-of-list reach,
detail expand/collapse and reverse scrolling to the first entry, followed by
product/database restoration. This establishes the current settings revision's
device evidence, rather than borrowing the earlier alpha8 device result.

The real page's initial DNS answer was a loopback address. A documented device
Private DNS change restored verified HTTPS and WebView loading. The media CDN
was a separate fault: direct connections to several public CDN nodes reset
during TLS negotiation, while an existing subscription's isolated outbound
returned the same key and TS with normal certificate verification. This does
not establish whether the reset originated at a middlebox or the remote edge,
and does not justify changing signed resource hosts, permitting private targets,
downgrading HTTPS or bypassing certificate validation in the application.

The proxy run uncovered a host bug: `onReceivedSslError` cancelled a third-party
tracking request but also revoked the entire main document and published its
URL as the tab's failure. Every SSL handler is still cancelled. A separate
navigation identity policy now distinguishes main-document URLs, redirects and
retired navigations from unrelated subresources; it does not grant script or
network authority. Redirect callbacks must still own the current SSL navigation;
preparing another navigation retires that identity before the next start. Native
unit and source-wiring regressions cover delayed errors and retired redirects.
Native transfer failures now expose bounded phase, hostname,
attempt, offset, byte count, selected route type and classified reason, without
serializing provider exception messages, signed URLs, proxy addresses or cookies.

The final protected real-page run verified both explicitly exposed episode URLs
and downloaded the selected episode completely: 78,669,748 bytes, 40 segments
and one AES key. It validated all local input paths and required every playlist,
key/init/segment file to be nonempty. The normal product package, this phone's
database SHA-256 and all temporary proxy settings were restored. The earlier
failed batches remain failures. Their short proxy lease could expire before a
long real download; the final isolated test extended only its total deadline
while retaining heartbeat-loss rollback. No permanent phone-to-workstation
proxy, production transport fallback or proxy configuration change was added.

This establishes current-page download and binding behavior. Manual story
comparison, the remaining real episode pages, real receiver DLNA, iOS and the
unavailable API/rendering matrix remain separate unfinished gates.

After fast-forwarding to alpha10 (`a28ce05`), the combined local check passed
549 Flutter tests plus analyzer and JS/Python contracts. Native unit tests
passed 83 cases; the SSL/navigation source contract passed 17. Independent
narrow review approved the SSL fix and upstream integration. The protected
alpha10 settings rerun passed both the 85-codec premium viewport case and
settings/themes/backup/cold-tab restoration, then restored this device's own
database and normal debug product. An earlier interrupted run executed no
assertions and remains a failed batch. These scoped results do not turn the
earlier failed full L3 run into a pass, nor establish a new published release.

## Final alpha10 regression checkpoint (2026-10-23)

The failed full run and a repeated script enable/reload test reproduced the
same WebView 155 main-process SIGSEGV at address 0x18. Matching provider source
and disassembly point to a null native messaging reply proxy during listener
reconfiguration; complete upstream symbols were unavailable, so this is not a
claim of a formally confirmed upstream bug. The host now registers a fixed pool
of 32 isolated worlds and listeners before any document executes. Navigation,
script replacement and script-count growth reuse those listeners. Bindings are
revoked immediately, each document receives new tokens, and asynchronous replies
must still own their original binding. A 33rd privileged script is explicitly
rejected rather than silently skipped or assigned weaker privileges.

Independent final review approved the fixed pool and episode identity changes.
The final protected L3 run passed all 32 device assertions and restored this
phone's own database and normal debug product. It includes 12 enable/reload
cycles, script-slot reassignment, adding a script while acknowledged GM.setValue
calls cross the native bridge, and overflow rejection. It also covers the
85-codec premium viewport, browser notification controls, aspect-preserving
thumbnails, both exported-MP4 ownership layouts and five Media3 fixture variants
with playback and seek. The local gate passed 549 Flutter tests, analyzer and
JS/Python contracts; native tests passed 83 cases. The ordinary suite explicitly
skipped its opt-in system-proxy fixture; earlier dedicated proxy/download
evidence remains separately identified. Historical failed and interrupted runs
remain failed or interrupted, and no new release was published.

The eight real playback pages separately passed authorization-normalized resource
identity comparison (content selectors retained; rotating credentials removed)
for their sliding current/neighbor episode windows, covering episodes 1–8 in
aggregate. That batch preceded the final API URL-string guard and generic timing
refinement. Fifteen deterministic identity regressions cover mixed old/new
maps, reused players, foreign API responses and ownerless timing. Neither the
page windows nor opaque resource URLs prove narrative content or authorize
guessing unexposed episode resources.

Device DNS comparison received A=0.0.0.0 with a successful DNS response code on
the original DNS path. Another public resolver's plaintext UDP did not respond.
Validated Private DNS restored the page to HTTPS 200; this does not identify
which resolver or middlebox imposed the original sinkhole. The CDN's separate
direct TLS resets remain unresolved at the network boundary; the earlier
verified proxy route completed the real download with certificate validation.

Seventy-five read-only samples during the debug suite observed app PSS up to
923,237 KiB and up to six WebViews. Without a same-scenario baseline or a long
post-disposal series, these measurements do not establish a memory-leak fix or
an acceptable memory cost for 32 pre-registered isolated worlds. Native-player
service ownership, streaming-save P0–P8, real SAF/DLNA, old-token migration and
the remaining API/rendering/iOS matrix retain their separate unfinished status
in `active-work-plan.md`.

## Retired-navigation callback regression (2026-10-23)

A subsequent narrow audit found that asynchronous app navigation preparation
retired script bindings but retained the previous Navigation/Page references.
An old completion could consume the new entry/history state or publish the old
URL under the new generation. An old main-frame network/HTTP error likewise
revoked the new lease without checking which document failed. Both preparation
paths now retire Navigation, Page and SSL navigation references before waiting
for Dart. Ordinary main-frame errors use the existing full-document URL policy;
current entry and redirect failures remain errors, with no TLS bypass.

The two new wiring regressions reject the old code in an in-memory comparison.
Two additional policy tests cover retired errors while a new document prepares
or starts, and current redirect failures. Native tests pass 85 cases; the full
local gate passes 549 Flutter tests, analyzer and JS/Python contracts. Seven
protected device navigation cases pass, including history, same-document SPA,
entry redirects and rejecting page-started privilege inheritance. Final narrow
independent review is APPROVE. The same final source also passes eight real
playback-page binding checks and restores its normal product and own database.
This supersedes the earlier eight-page batch's source-version limitation;
it does not turn opaque resource URLs into proof of narrative content or add
direct-CDN download evidence. The earlier full 32-case suite remains a separate
checkpoint; unchanged media fixtures were not replayed for this narrow fix.

Ordinary WebView error callbacks expose no navigation ID. Old and current loads
of an identical URL cannot be distinguished by this URL policy; same-URL ABA
callback attribution remains an explicit platform limitation.

The same source was then run through the isolated system-proxy fixture. HTTP and
HTTPS CONNECT, redirect, exact local playlist and segment hits, and the media
discovery/download contract passed. A detached device watchdog restored all
proxy fields after the host process was killed in 22.38 seconds. The final
read-only network check reported validated Wi-Fi, HTTP 204 and HTTPS 200, with
the reverse port removed. This does not change the separate direct-CDN TLS reset
finding or prove a permanent proxy policy for production traffic.

The requested emulator matrix remains incomplete. At the final checkpoint,
`adb devices` contained only the API 34/WebView 155 phone and no
`emulator-5554`. Host swap free was about 668 MiB, below the emulator
validation stop threshold of 1 GiB, so no new emulator was started or replayed.
The previous API 37 boot-complete observation remains startup evidence only; it
does not establish Media3, HCPP, codec diagnostics or compatibility-glass
acceptance on an emulator.

## Alpha12 follow-up: application HTTPS and document-lifetime evidence

The current `145ab61` worktree has a separate protected API 36 / WebView 155
checkpoint. The local gate passes 578 Flutter tests, analyzer and JS/Python
contracts. This reuses unchanged Media3 parity evidence from the prior complete
35-case device run; it does not rewrite historical failures or release a package.

The opt-in system-proxy suite passes nine cases with restoration. Its five HTTPS
stages cover application discovery, Dart fetch, Android TLS file transfer,
WorkManager download and a complete fixed upstream Media3 HLS VOD. The latter
checks the manifest, init and both fragments by exact length and SHA-256, then
validates the local playlist/resource boundary. It has no encryption key and
does not claim AES network-download, playback or remux evidence. Each stage
requires its own bidirectional encrypted proxy traffic, separately from content
validation; persistent connection reuse is permitted. Proxy fields, ordinary
Internet checks, the normal product APK and the same-device database restore
all pass. Test/fixture/orchestrator narrow independent review is APPROVE.

The real WebView lifecycle fixture separates delayed fetch ep2 and XHR ep1,
completes inside four seconds to exclude the five-second clone timeout, and
keeps both original mappings after synthetic pagehide/pageshow. A newly declared
ep3 reappears, and unbound same-page requests retain an unknown episode label.
These assertions pass on device, but synthetic events do not prove physical
BFCache residency. Final-route selection is also checked on the real first and
second playback pages; authorization-normalized resource identity is not proof
of narrative content.

Sampled system screenshots of the codec scroll showed no black blocks or
duplicate painting in the reviewed frames. At that checkpoint, WebView/video
overlay pixels and the light/dark by 0/55/100 matrix were still missing. The
follow-up below supplies a scoped physical-device matrix; continuous scrolling
and the remaining device/GPU combinations remain incomplete. Earlier emulator
memory failures are retained as historical evidence.

## HCPP compositor matrix and direct-native popup roles

The opt-in fixture and host observer now capture eighteen real Android
compositor frames: light/dark by 0/55/100 fill, across the browser, an overlay
intersecting the playing video and a Flutter-owned page. Each checkpoint checks
the effective engine HCPP predicate and ongoing playback. Each overlay maps
fresh video edges and the current visual viewport into Flutter coordinates;
intersection and a partly visible video are required. The observer uses a fresh
run nonce, ordered acknowledgements and foreground/window checks before and
after capture. Missing or ambiguous ownership refuses capture. The canonical
runner continues to own installation and same-device database restoration.

Early failures are retained: a duplicate CLI target whitelist, an observer
lifetime error requiring an explicit protected restore, a locked-device driver
failure, and missed fixture clicks. Android 16 requires the full window dump
for global focus. Fixture text overflow is bounded; visualViewport coordinates,
actual pointer target and a single successful playback click are verified.

The `visual9` suite and restoration passed, but pixel review failed: a
transparent overlay directly over native video used the ordinary panel shader
role and became opaque black at zero fill. The real browser new-tab prompt had
the same undeclared native backdrop. It now passes an explicit `platformView`
role through `promptNewTab`, `promptText` and `SiteLensAlertDialog`. Ordinary
Flutter prompts retain the panel default. Direct-native surfaces keep the
existing polarity backer/fill; HCPP and premium Flutter pages remain enabled.
There is no new native screenshot/texture bridge or claim of native refraction.

The final `visual10` protected API 36 / WebView 155 run passes all eighteen
captures plus six actual browser new-tab dialog checks. The latter verify the
native role, exact configured alpha, the shader-free fill path and cancellation
without creating a tab. Flutter-owned pages still check actual premium widgets,
no compatibility fallback and selected alpha. All eighteen image hashes match;
reviewed frames show no unexpected opaque black body, duplicate painting or
app-panel clipping. The zero-fill native overlay intentionally retains its
contrast backer. A constant system-sidebar indicator is outside the app pixel
assessment. The solid-color synthetic video checks playback time, not motion
between decoded frames. These static frames do not prove continuous scroll or
animation behavior, other APIs, non-Vulkan devices or other GPUs.

The final local gate passes 580 Flutter tests, analyzer and JS/Python contracts.
Visual tooling, runner and backup-identity tests pass 13, 45 and 13 cases;
narrow independent code review is APPROVE. The normal product package and the
source-bound same-device database restore with matching SHA-256. This is a
targeted checkpoint, not a new full L3 result or release. Native background
service/queue B0–B3 and streaming-save P0–P8 remain separate unfinished plans.
