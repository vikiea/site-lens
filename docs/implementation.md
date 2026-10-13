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
