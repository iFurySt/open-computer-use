param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# The runtime's production dispatch and integrity check, with stubbed actions and a Win32 double for integrity
# levels. Runs under pwsh on any OS.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$check = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Assert-InputAllowed" }, $true))
$dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match '\$operation\.tool' })
if ($check.Count -ne 1 -or $dispatch.Count -ne 1) { throw "Production integrity check or dispatch missing" }
Invoke-Expression $check[0].Extent.Text
Add-Type -TypeDefinition @"
public static class OCUWin32 {
 public static int target = 0x2000, own = 0x2000, host = 0x2000;
 public static int IntegrityLevel(uint processId) { return processId == 42 ? target : processId == 43 ? host : own; }
}
"@
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Start-Sleep { param($Milliseconds) }
function Resolve-App($query) { [pscustomobject]@{ Id = 42; ProcessName = "fixture"; MainWindowHandle = [IntPtr]42 } }
function Assert-WindowResponds($hwnd, $name) { }
function Find-Element($process, $record) { $null }
function Send-Key($hwnd, $key, $method) { $script:sent++ }
function Resolve-ObservationOptions($operation) { [pscustomobject]@{ include_ax = $true; include_screenshot = $true } }
function Resolve-TextLimit($value) { 500 }
function Build-Snapshot { [pscustomobject]@{ app = [pscustomobject]@{ pid = 42 } } }
function Dispatch($tool, $target, $own) {
    [OCUWin32]::target = $target; [OCUWin32]::own = $own; $script:sent = 0
    $operation = [pscustomobject]@{ tool = $tool; app = "fixture"; key = "Return" }
    $response = $null
    Invoke-Expression $dispatch[0].Extent.Text
    return $response
}

$r = Dispatch "press_key" 0x3000 0x2000
Assert (-not $r.ok -and $r.error -match "runs elevated" -and $script:sent -eq 0) "Input to an elevated window was sent: $($r | ConvertTo-Json -Compress)"
$r = Dispatch "press_key" 0x2000 0x2000
Assert ($r.ok -and $script:sent -eq 1) "Input at the same level was refused"
$r = Dispatch "press_key" 0x3000 0x3000
Assert ($r.ok -and $script:sent -eq 1) "Input from an elevated runtime to an elevated window was refused"
$r = Dispatch "press_key" 0x2000 0x3000
Assert ($r.ok -and $script:sent -eq 1) "Input to a lower level was refused"
$r = Dispatch "press_key" -1 0x2000
Assert (-not $r.ok -and $r.error -match "Cannot verify" -and $script:sent -eq 0) "An unreadable target level allowed input"
$r = Dispatch "press_key" 0x2000 -1
Assert (-not $r.ok -and $r.error -match "Cannot verify" -and $script:sent -eq 0) "An unreadable runtime level allowed input"
$r = Dispatch "get_app_state" 0x3000 0x2000
Assert ($r.ok) "Observing an elevated window was refused"
Write-Output "Integrity: elevated target refused before input, same/higher/lower levels allowed, unknown refused and observation allowed passed."

[OCUWin32]::target=0x2000;[OCUWin32]::own=0x2000;[OCUWin32]::host=0x3000
$failure=$null
try { Assert-InputAllowed ([pscustomobject]@{Id=42;ProcessName='hosted';Hosted=$true;HostProcessId=43}) } catch { $failure=$_.Exception.Message }
Assert ($failure -match 'host runs elevated') 'Higher-integrity host was ignored'
