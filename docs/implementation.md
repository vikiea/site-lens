# Implementation notes

Site Lens is an Android-first, local-first Flutter application for manually selected site discovery and browsing. The iOS host sources and contract entry points remain in the repository, while the current release and acceptance scope is Android.

## Architecture

- `lib/domain` contains site, candidate, probe, script, and browser models.
- `lib/data` contains Drift/SQLite persistence and schema migrations.
- `lib/network` enforces public-address, TLS, redirect, and per-hop network policy.
- `lib/discovery` performs bounded HTTP screening and serial DOM verification.
- `lib/scripts` parses userscripts and runs the capability-gated GM subset.
- `lib/browser` and `lib/web_host` coordinate persisted tabs and native WebView hosts.
- `pigeons/web_host.dart` is the typed cross-platform host contract.

## Data and security boundaries

The application stores site profiles, candidates, probe history, scripts, approved dependencies, script values, and browser-session metadata in its private SQLite database. Browser cookies, Web storage, runtime handles, and unapproved script state are kept outside business backups. Network access is fail-closed: private or reserved addresses, URL credentials, unapproved domains, and invalid TLS are rejected.

Users select sites manually. Detection results are scoped to the current round, and historical reachability is not presented as current verification. Entry redirects, navigation leases, scripts, permissions, and media controls are independently checked.

## Media authorization refresh

A media address expires with the page that authorized it, so a retry cannot simply reuse the stored address. The refresh path reloads the 来源页 (source page) headlessly, accepts only the main playlist request that the page itself issues, and adopts that address under three honest outcomes:

- **授权刷新 (authorization refresh)**: the page handed over its own main playlist address, which replaces the stored one; the task resumes. Cookies stay in the platform layer, and the address is never written to a log line.
- **授权未变化 (unchanged)**: the page loaded and changed nothing observable, so retrying the same page cannot help. The task keeps its state.
- **需回来源页 (page reauthorization required)**: no usable address was obtained; the user has to return to the 来源页 and pick the media again. The task keeps its state.

The three outcomes are the vocabulary the UI uses; free-form instructions say 来源页, never 播放页. A refresh that reports success but whose address cannot be adopted degrades to 需回来源页 rather than 授权未变化, because the page did answer and only its hand-over failed.

A play address is resolved by the page through several hops and routinely lives on another registrable domain, so nothing about the capture path is gated on the page's site: any main playlist the loaded page itself asks for is its address, wherever it is served. That also means the page load is never vetoed — a layout redirect, a host shim, or a canonical rewrite of the episode URL is normal navigation.

Ownership rules are fail-closed. An adopted address must be HTTP(S), carry no embedded credentials, pass media candidacy validation, and replace the same resource for the same task: same scheme, host and port, with the path equal or an extension of the other's directory (the page decides its own spelling), and the query treated as the part a refresh replaces. A capture is attributed to the task whose own address it replaces, never to a task identity supplied by a caller, and one address never serves two tasks. Tasks that share one 来源页 are refreshed in one page load, and each of them receives only its own address.

A successful refresh is authoritative. The address it produced has already passed every gate above, so a live tab that has since moved to another generation or another episode cannot veto it — otherwise a refresh that worked would still report 需回来源页.

The 来源页 entry in a task's menu opens that page in the app's browser tab, reusing an existing tab. It opens exactly the page the task records and refuses any page the task cannot vouch for, and it reports success only when the browser is actually showing the page. Persistent outcomes such as 需回来源页 or 授权未变化 are shown on the page's shared notice surface with the 打开来源页 action; a resumed transfer stays a short confirmation.

## Media resume

Bytes on disk are never discarded by the client. Both transfer paths — the native worker and the Dart HLS path — take the file length as the offset, offer it as `Range`, and let the server decide: `206` continues from the offset, `416` whose range equals the file length means the file is already complete, and only a `200` rewrites from the start. A missing `ETag`/`Last-Modified` is no longer read as "cannot be stitched" and a rotated validator no longer clears bytes the server already confirmed; the validator is remembered, and it serves only as an `If-Range` hint. A partial file with no metadata beside it is still a partial file.

A retry never deletes bytes either. The `cache_missing` path used to delete the native partial before restarting; it now resumes it, because losing the bytes is the one outcome the user cannot tell apart from "downloading from zero". Native `status` reports `cache_missing` only when the worker finished successfully and the final file is gone — never merely because the runtime has no record.

The batch refresh is part of the `site_lens/media_auth` platform protocol: the channel accepts `refresh` for one task and `refreshBatch` for many, both speaking the same field layout, and answers every request exactly once.

## Development and verification

Run the repository gate with:

```sh
flutter pub get
make check
```

`make check` runs Flutter analysis and tests, regenerates and checks the Pigeon bindings, and validates the JavaScript runtime contract. Android device flows use the canonical `make acceptance DEVICE=DEVICE_ID` entry point, which handles the debug package, database backup and restore, integration suites, and restoration of the normal debug APK. Formal release installation and smoke checks are separate steps.

The formal Android package is `dev.vikiea.site_lens`; the debug and acceptance package is `dev.vikiea.site_lens.debug`. The package identifiers and database filename are stable application identities and are intentionally independent from the GitHub repository name `site-lens`.

## Release boundaries

Release signing material is read from outside the repository. CI builds and validates the debug APK; formal release signing and device acceptance require the local signing configuration described in [Android modernization](android-modernization.md).
