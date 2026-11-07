# Windows target capture and child click routing

## Request

Reproduce screenshots disagreeing with the selected application and ordinary
clicks reporting success without reaching a nested control on Windows.

## Changes and rationale

- `apps/OpenComputerUseWindows/runtime.ps1`: capture the selected HWND with
  PrintWindow instead of cropping desktop pixels; retain physical full-window
  coordinates, geometry checks, disposal and fail-closed image omission.
- Route posted clicks through the target's child hierarchy; validate process,
  enabled state, client point, current window/element geometry and delivery.
  Attempt mouse release on interrupted/failed down delivery.
- `scripts/tests/fixtures/WindowsTargetFixture.ps1` and
  `scripts/tests/windows-target-smoke.ps1`: real native MCP before/after regression
  at 200% DPI, distinguishing delivery from semantic action acceptance.
- `scripts/tests/windows-target.test.ps1`: production-function fault injection
  for child-local coordinates, stale/invalid input and message failure cleanup.
- Correct the existing WPF smoke helpers for PowerShell 5.1 array shape, UTF-8 input and localized control roles, with regression checks.
- Update the observation test to check that capture receives the target HWND;
  wire regression tests into the existing Windows workflow and document limits
  in `docs/windows-targeting.md` and the feature release notes.

## Validation

The v1.1.3 baseline reproduces both defects: pink occluder pixels replace the blue
window, and the nested button receives no mouse-up despite a successful call.
The patched native bridge captures blue pixels under cover and delivers child
button/panel mouse events; a standard native-style button's Click counter also
increments through `auto`. Go tests, PowerShell observation/input fault tests and
the new posted-input fault tests pass. Native MCP also checks disabled controls,
stale window/element geometry, invalid points and minimized-image omission.

## Boundaries

No global input is enabled implicitly. PrintWindow support depends on the target
renderer; a successful posted message does not guarantee toolkit acceptance.
Owner-drawn controls rejecting background input remain a documented limitation.

## WPF observation validation

The complete existing WPF/native MCP/CLI/Worker JS observation smoke passes on
the tested Windows desktop after correcting its PowerShell 5.1 and localization
assumptions: preserve single-image arrays, match the fixture's stable name rather
than the localized `edit` role, and encode JSON-RPC input explicitly as UTF-8.
The initial "missing image" failure was a harness assertion error: diagnostics
showed one actual image while the scalar object's Count property was null.

Coverage includes selective channels, stale-index rejection and AX recovery,
real Unicode value updates, and image omission/recovery for 1x1, minimized and
cloaked windows. The Worker JS path also passes. These results do not establish
support for every Windows toolkit or renderer.

The native smoke supports opt-in cropped evidence output. The before/after PNG
in `docs/assets/windows-target-capture.png` contains fixture pixels only.

## 2026-11-07 maintainer review

User requested integration with current main, actual Windows testing and merge
after validation. Merged main including v1.1.4 without conflicts. Added guards
against a child moving while retaining its HWND, including between repeated
clicks; regression tests check no stale click and mouse-up after interruption.
The hosted Windows workflow compares the candidate with pinned v1.1.4 using
the same fixture and retains cropped fixture-only evidence.


Validation on reviewed code `ddf846b`:

- [Hosted Windows run](https://github.com/iFurySt/open-computer-use/actions/runs/42350802353) passed all steps on `windows-2025`, actual fixture DPI 96 (100%).
- Pinned v1.1.4: child mouse-up delta 0; occluded capture sampled RGB `220,30,120` (occluder). Candidate: delta 1; RGB `20,80,180` (target).
- Candidate passed covered auto/button, posted left/right/panel delivery, disabled/outside/stale-target refusal, minimized-image omission, and production moved-child/interruption tests.
- Existing WPF set-value, selective observation, Unicode, native MCP/CLI/Worker JS, physical input, scrolling and tree-budget smoke passed.
- Local Go tests/vet, 48 Node tests, docs and whitespace checks passed. No macOS/Linux production behavior changed.
- Cursor coordinates stayed unchanged in covered-click observations. The first covered posted click changed the foreground HWND; no guarantee of foreground stability is claimed. The posted path has no explicit activation/global-pointer calls, but a receiving application can change focus itself.
- Author evidence at 200% remains separate; this hosted run adds 100%, not 150% or mixed-monitor validation. GPU/protected renderer support is still limited by PrintWindow. Posted drag/keyboard routing from #91 is outside this PR.
- Fixture-only screenshot artifacts were uploaded; local artifact download hit a network TLS timeout. Pixel assertions and independent counters are available in the successful run logs.

Final PR head `881ac1c` passed the complete [Windows workflow](https://github.com/iFurySt/open-computer-use/actions/runs/42351354214).
Commented `LGTM. Thanks!` and squash merged #147 as `4dbaa7a`, retaining contributor
authorship and the maintainer co-author. No version bump or release was made.
