# Browser enhancement implementation matrix

This matrix is the implementation baseline for the feature branch. It records
what is present in the checkout, what this work closes, and which evidence is
required before a release can claim the corresponding plan.

| Plan | Document requirement | Existing implementation at start | Gap closed in this change | Acceptance evidence |
| --- | --- | --- | --- | --- |
| 00 | Ordered gates, rollback boundaries, release/version protection | CI gates and atomic version reservation are present on `main` and merged here | Keep the reservation workflow; add this matrix and a media acceptance report so release notes cannot claim unverified device behavior | `tool/verify_level.py --auto`, workflow checks, report fingerprint |
| 01 | v5 metadata schema, v3 profile packs, immutable DTOs and backup exclusions | Drift v5, ProfilePack v3, filtering/media rows and Pigeon metadata DTOs exist | Add explicit DTO conversion helpers and backup assertions for media cache/task credentials; preserve fail-closed import | migration/profile/backup tests |
| 02 | Request filtering, cosmetic CSS, audited DOM scriptlets, diagnostics and safe fallback | In-memory request blocking and CSS mutation observer exist | Add a small allow-listed scriptlet compiler/runtime and expose blocked/unsupported diagnostics without executing remote JavaScript | filter parser/runtime tests and host contract |
| 03 | Declared/public approval, generation checks and `registerMedia` | Script approval formats, generation checks and registration bridge exist | Add regression coverage for public approval invalidation and registered candidate persistence; no credential fields are accepted | `gm_authorization_test.dart`, script verifier |
| 04 | Candidate collection and Android native playback session | DOM/script candidates and a platform `MediaPlayer` bridge exist | Make the native bridge stateful (buffering/completion/error), expose candidate playback action in the task UI, and keep iOS explicit unsupported | native host contract plus Android media flow |
| 05 | Durable native download/background task store and complete UI | Dart task store and Android `DownloadManager` bridge exist, but UI only starts a download | Persist native download metadata, reconcile status after process restart, and add a task screen with pause/resume/cancel/delete/play actions | task-store tests, Android acceptance download flow |
| 06 | Local-only HLS input, restricted FFmpeg/JNI boundary, MP4 validation and SAF delivery | Dart parser/validator and SAF copy bridge exist; no executable mux path | Add a JNI entry point with local-path validation and Android `MediaExtractor`/`MediaMuxer` remux fallback for cached HLS, progress/cancel/error mapping, and tests | HLS parser/export tests; real-device playback remains L3 pending |
| 07 | UPnP discovery/SOAP, one cast session, bounded MP4/HLS relay | SSDP, AVTransport SOAP, single-session controller and MP4 relay exist | Add token-bound HLS manifest/segment/key relay and `GetProtocolInfo` capability parsing; keep relay scoped to one approved task/device | relay unit tests; real receiver playback remains L3 pending |
| 08 | Cross-module regression and L0-L4 delivery evidence | Existing acceptance runner covers browser/update/media policy | Add media task/export/cast assertions to the acceptance suite and a command that records skipped real-device gates | `make check`; `make acceptance DEVICE=...` when device is available |

Device-only limitations are reported separately. A passing local check never
turns a missing Android receiver, DRM stream, or signed release installation
into a passed L3/L4 gate.
