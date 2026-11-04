# Release artifact evidence

Read this when reporting evidence for a routine GitHub Release or deciding whether release assets must be downloaded.

For a routine GitHub Release, treat release completion as the combination of a successful `Release Site Lens` workflow and a published Release asset digest. Confirm both with `gh run view <run-id> --json status,conclusion,jobs` and `gh release view <tag> --json isDraft,isPrerelease,assets,url`; record the APK asset name and its `digest` value when available.

Do not download the APK or checksum asset during routine validation. Download and locally verify assets only when the user explicitly requests it, a device installation is part of the current acceptance gate, the package/signature/version identity must be inspected, or the workflow/Release metadata shows an anomaly or lacks a digest.
