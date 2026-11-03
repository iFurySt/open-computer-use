# Windows target capture and posted click correction

## Objective and scope

Reproduce occluded screenshots and lost nested-control clicks on a native Windows desktop. Capture the selected HWND, route posted messages to the target child, retain physical coordinates and explicit global-input opt-in, and add reproducible regression evidence.

## Completed validation

- Original v1.1.3 reproduces both defects with disposable WinForms windows at 200% DPI.
- Patched native MCP validates target pixels, button/panel counters and invalid/stale-target refusal.
- Existing full WPF/native MCP/CLI/Worker JS observation smoke passes after fixing its PowerShell 5.1 array/UTF-8 and localized-role assumptions.
- Windows Go tests/vet, production PowerShell checks and documentation validation pass.
- The optional evidence output crops away desktop edge pixels. The comparison image is based on actual native MCP captures from the final local candidate.

## Limits and delivery

100%, 150% and mixed-DPI transitions were not independently tested. PrintWindow and background mouse acceptance remain renderer/toolkit dependent. See `docs/windows-targeting.md` for commands and scope. No version bump or implicit global input is included.

Implementation and local review package are prepared. Remote submission is a separate step requiring the user's confirmation; the installed managed runtime remains unchanged.
