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
- [ ] Review/fix production paths and strengthen regression coverage.
- [ ] Run local checks and hosted Windows before/after and existing regressions.
- [ ] Record evidence, push contributor branch, comment LGTM and squash merge.
