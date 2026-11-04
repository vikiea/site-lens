# Manual device evidence

Read this when a developer has manually verified the acceptance checklist on a real device and a passed evidence file must satisfy a required device stage.

A passed manual evidence file may satisfy a required device stage when a developer has manually verified the checklist on a real device. Create it with `make manual-evidence-template`, approve every item with `make manual-evidence-approve`, and pass it using `--manual-evidence`. The runner must validate the evidence schema, requested level, changed paths, content fingerprint, and complete worktree fingerprint before accepting it; never treat an unchecked or stale file as device evidence.