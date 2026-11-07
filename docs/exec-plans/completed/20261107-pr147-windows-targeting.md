# PR #147 Windows target capture and posted clicks

## Goal

Review against current main, reproduce both reported defects on hosted Windows,
fix review findings, and merge the original contributor PR after validation.

## Scope and decisions

- Preserve target-window screenshots and explicit global-input opt-in.
- Cover real WinForms/WPF behavior through native MCP and existing JS smoke.
- Compare an unmodified main executable with the candidate using the same fixture.
- Check independent pixel/event counters, stale targets, delivery failures and cleanup.
- Record actual DPI and renderer coverage; do not claim mixed-DPI or universal GPU capture.
- No local VM or changes to the user's desktop/installed runtime.

## Progress

- [x] Read PR and synchronize current main; merge without conflicts.
- [x] Review/fix production paths and strengthen regression coverage.
- [x] Run local checks and hosted Windows before/after and existing regressions.
- [x] Record evidence, push contributor branch, comment LGTM and squash merge.


[Hosted Windows evidence](https://github.com/iFurySt/open-computer-use/actions/runs/42350802353)
passed on `ddf846b`, with actual DPI 96. Both defects reproduced on pinned v1.1.4
and disappeared on the candidate. Local Go/vet, 48 Node tests and docs passed.
Foreground stability is not guaranteed; 150%/mixed DPI and GPU applications remain
outside independently verified coverage. See the existing review history for details.

Final head `881ac1c` passed [the complete Windows run](https://github.com/iFurySt/open-computer-use/actions/runs/42351354214).
PR #147 received `LGTM. Thanks!` and was squash merged as `4dbaa7a`, preserving
the original author and maintainer co-author. No release version was changed.
