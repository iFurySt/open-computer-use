# Windows selected text

Chromium/Electron UIA providers can crash Windows PowerShell 5.1 while reading
`TextPatternRange.GetText`. A PowerShell `try/catch` does not reliably contain
this native access violation. Selected text is optional; the tree and screenshot
remain available when it is withheld.

Before reading TextPattern, OCU checks the target's native window class without
creating another UIA element. `Chrome_*` windows omit selected text. A missing,
reused or unclassifiable window also omits it. Focused controls identified as
Chromium by their framework/class are excluded even under a native host window.
The existing password guard remains in place. Ordinary native controls retain
selected text and the configured text limit.

The check does not fix the third-party provider or guarantee all UIA operations
are crash-free. The specific Opera GX/Electron crash in #162 is reporter evidence;
our independent guard tests prove the risky path is not entered, and the real
Edge/WPF smoke checks observation, actions and native selection on Windows.

## Tests

```powershell
powershell.exe -NoProfile -File scripts/tests/windows-observation.test.ps1 -RuntimePath apps/OpenComputerUseWindows/runtime.ps1
./scripts/tests/windows-observation-smoke.ps1 -NativePath <built-executable>
```

The real browser test uses a temporary Edge profile and a fixture-only local
page; it closes only that profile. It is included in the existing Windows
observation workflow. No macOS or Linux input behavior changes.
