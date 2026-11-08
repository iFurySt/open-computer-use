param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Production hang probe, Get-MainElement and dispatch over Win32/UIA doubles. Runs under pwsh on any OS; a real
# window that stops pumping is a desktop test.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Assert-WindowResponds", "Get-MainElement")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
$dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match '\$operation\.tool' })
if ($functions.Count -ne $names.Count -or $dispatch.Count -ne 1) { throw "Production hang probe, window lookup or dispatch missing" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class OCUWin32 {
 public static Queue<bool> hung = new Queue<bool>();
 public static int probes;
 public static bool IsHung(IntPtr hWnd, uint timeoutMs) { probes++; return hung.Count > 0 && hung.Dequeue(); }
}
namespace Windows.Automation {
 public static class AutomationElement {
  public static int reads;
  public static object FromHandle(IntPtr hWnd) { reads++; return "window"; }
 }
}
"@
$HangProbeTimeoutMs = 1000
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Reset([bool[]]$answers) {
    [OCUWin32]::hung.Clear(); foreach ($answer in $answers) { [OCUWin32]::hung.Enqueue($answer) }
    [OCUWin32]::probes = 0; [Windows.Automation.AutomationElement]::reads = 0; $script:sent = 0
}
$process = [pscustomobject]@{ Id = 42; ProcessName = "fixture"; MainWindowHandle = [IntPtr]42 }

Reset @($true, $true)
$failure = $null
try { Get-MainElement $process | Out-Null } catch { $failure = $_.Exception.Message }
Assert ($failure -match "fixture is not responding" -and [Windows.Automation.AutomationElement]::reads -eq 0) "A hung window was read with UI Automation: '$failure', reads=$([Windows.Automation.AutomationElement]::reads)"
Reset @($true, $false)
Assert ((Get-MainElement $process) -eq "window" -and [OCUWin32]::probes -eq 2) "A window busy for one probe was refused"
Reset @()
Assert ((Get-MainElement $process) -eq "window" -and [OCUWin32]::probes -eq 1) "A responsive window was probed twice"

function Start-Sleep { param($Milliseconds) }
function Resolve-App($query) { $process }
function Find-Element($proc, $record) { $null }
function Send-Key($hwnd, $key, $method) { $script:sent++ }
function Build-Snapshot { [pscustomobject]@{ app = [pscustomobject]@{ pid = 42 } } }
function Dispatch($operation) { $response = $null; Invoke-Expression $dispatch[0].Extent.Text; return $response }
Reset @($true, $true)
$r = Dispatch ([pscustomobject]@{ tool = "press_key"; app = "fixture"; key = "Return" })
Assert (-not $r.ok -and $r.error -match "not responding" -and $script:sent -eq 0) "A key was posted to a hung window: $($r | ConvertTo-Json -Compress)"
Reset @()
$r = Dispatch ([pscustomobject]@{ tool = "press_key"; app = "fixture"; key = "Return" })
Assert ($r.ok -and $script:sent -eq 1) "A key to a responsive window was refused"
Write-Output "Hang probe: hung window refused before UI Automation and input, busy window recovered, responsive window probed once passed."
