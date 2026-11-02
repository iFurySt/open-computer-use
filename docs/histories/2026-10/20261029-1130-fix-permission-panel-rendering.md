# Restore permission guidance after an interrupted launch

## Problem and reproduction

The macOS permission guidance panel animates from a 104×44 button frame to 530×109.
If System Settings loses foreground during launch, visibility tracking cancels the
animation and hides the panel. Returning to Settings previously updated only its
position, leaving an intermediate size and opacity. At 0.18 seconds the panel is
303×75, placing the draggable tile 15pt below its bottom edge. Normal completion
also derived its target size from the final sampled frame, leaving 524×108.

## Change

Use the layout's full size for placement, launch targets and completion, and restore
opacity when showing the panel after an interruption. Inject a Settings window
provider and animation clock so tests drive the real controller without granting,
resetting or requesting TCC permissions. Preserve the existing artwork and copy.

## Regression coverage

- Hide/show at five launch times: 0, 0.05, 0.18, 0.4 and 0.7 seconds.
- Normal completion uses the exact target size.
- Starting another permission step after an interrupted launch uses the full size.
- Assert panel opacity and containment of the back button, label and draggable tile.

Run from the repository root:

```sh
mkdir -p .build/permission-panel-snapshots
OCU_TEST_SNAPSHOT_DIRECTORY=.build/permission-panel-snapshots \
  swift test --build-system native --scratch-path .build/permission-panel-tests \
  --filter PermissionAccessoryPanelTests
```

The native build mode supports the local Swift 6.4 toolchain. The fixture supplies
window context and time; the production NSPanel, layout, animation and visibility
logic are used directly. Real signed-app authorization and display scaling remain
separate release acceptance checks.

Validation: all three new regression tests fail with the old size/opacity behavior
and pass with the fix. The new tests plus existing permission/TCC tests pass
(13 tests); `make check-docs` and `git diff --check` also pass.
