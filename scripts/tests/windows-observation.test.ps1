param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"

# Execute the production observation functions with instrumented UIA/capture
# dependencies. This can run under pwsh on Linux; it is not a Windows UI test.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }
$functions = $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @("Resolve-ObservationOptions", "Build-Snapshot")
}, $true)
if ($functions.Count -ne 2) { throw "Production observation functions missing" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }

$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64
function Resolve-App($query) { [pscustomobject]@{ ProcessName = $query; Id = 42; MainWindowTitle = "Fixture"; MainWindowHandle = 123 } }
function Get-MainElement($process) { "window" }
function Get-WindowBounds($process, $element) { [pscustomobject]@{ x = 0; y = 0; width = 300; height = 200 } }
function Limit-Text($text, $limit) { $text }
function Render-Tree($element, $bounds, $limit, $nodes, $depth) {
    $script:calls.tree += 1
    [pscustomobject]@{ lines = @("Input"); records = @([pscustomobject]@{ index = 7 }) }
}
function Get-FocusedSummary($processId, $limit) { $script:calls.focus += 1; "focus" }
function Get-SelectedText($processId, $limit) { $script:calls.selection += 1; "selection" }
function Capture-WindowPngBase64($bounds, [IntPtr]$hwnd) { Assert ($hwnd -eq [IntPtr]123) "Capture did not receive target HWND"; $script:calls.capture += 1; "png" }
function Assert($condition, $message) { if (-not $condition) { throw $message } }

foreach ($mode in @(
    @{ ax = $true; image = $true },
    @{ ax = $true; image = $false },
    @{ ax = $false; image = $true }
)) {
    $script:calls = @{ tree = 0; focus = 0; selection = 0; capture = 0 }
    $snapshot = Build-Snapshot "Fixture" -IncludeAX $mode.ax -IncludeScreenshot $mode.image
    Assert ($snapshot.app.pid -eq 42 -and $snapshot.windowBounds.width -eq 300) "Window metadata missing"
    Assert ($script:calls.tree -eq [int]$mode.ax -and $script:calls.focus -eq [int]$mode.ax -and
            $script:calls.selection -eq [int]$mode.ax -and $script:calls.capture -eq [int]$mode.image) "Disabled collection still executed"
    if ($mode.ax) {
        Assert ($snapshot.elements.Count -eq 1 -and $snapshot.selectedText -eq "selection") "AX missing"
    } else {
        Assert ($snapshot.elements.Count -eq 0 -and $snapshot.treeLines.Count -eq 0 -and
                $null -eq $snapshot.focusedSummary -and $null -eq $snapshot.selectedText) "AX was not omitted"
    }
    Assert (($snapshot.screenshotPngBase64 -eq "png") -eq $mode.image) "Screenshot mode mismatch"
}

$defaults = Resolve-ObservationOptions ('{}' | ConvertFrom-Json)
Assert ($defaults.include_ax -and $defaults.include_screenshot) "Defaults changed"
foreach ($payload in @('{"include_ax":false}', '{"include_screenshot":false}')) {
    $flags = Resolve-ObservationOptions ($payload | ConvertFrom-Json)
    Assert (-not ($flags.include_ax -and $flags.include_screenshot)) "False flag lost"
}
foreach ($payload in @('{"include_ax":"false"}', '{"include_ax":0}', '{"include_screenshot":null}',
                       '{"include_ax":false,"include_screenshot":false}')) {
    $failed = $false
    try { $null = Resolve-ObservationOptions ($payload | ConvertFrom-Json) } catch { $failed = $true }
    Assert $failed "Invalid observation accepted"
}
$failed = $false
try { $null = Build-Snapshot "Fixture" -IncludeAX $false -IncludeScreenshot $false } catch { $failed = $true }
Assert $failed "Empty snapshot accepted"
Write-Output "PowerShell production functions: parse, defaults, strict booleans and all collection modes passed (instrumented dependencies)."

# Exercise the actual smoke helpers under both Windows PowerShell and pwsh.
$smokePath = Join-Path $PSScriptRoot "windows-observation-smoke.ps1"
$smokeAst = [System.Management.Automation.Language.Parser]::ParseFile($smokePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$helpers = $smokeAst.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @("Images", "Text", "Input-Index")
}, $true)
Assert ($helpers.Count -eq 3) "Observation smoke helpers missing"
foreach ($helper in $helpers) { Invoke-Expression $helper.Extent.Text }
foreach ($count in @(0, 1, 2)) {
    $result = [pscustomobject]@{ content = @(for ($i = 0; $i -lt $count; $i++) { [pscustomobject]@{ type = "image"; data = "fixture" } }) }
    Assert ((Images $result).Count -eq $count) "Smoke image count lost array shape"
}
foreach ($role in @("edit", "editable text", ([string][char]0x7F16 + [char]0x8F91))) {
    $result = [pscustomobject]@{ content = @([pscustomobject]@{ type = "text"; text = "  7 $role Observation input Value: fixture" }) }
    Assert ((Input-Index $result) -eq "7") "Smoke index lookup depends on the UI language"
}
Write-Output "Observation smoke helpers: zero/single/multiple images and localized control roles passed."
