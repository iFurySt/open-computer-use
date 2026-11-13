param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Production app/window resolution over a Win32 window-list double. Runs under pwsh on any OS; real UWP frames and
# modal dialogs are a desktop test.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Resolve-App", "Resolve-ModalWindow", "Get-AppWindows", "List-Apps", "Test-EnvFlagEnabled")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production resolution functions missing: $($names | Where-Object { $_ -notin @($functions | ForEach-Object Name) })" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class OCUWin32 {
 public class TopWindow { public IntPtr Handle, Owner; public uint ProcessId; public bool Enabled, Hosted; public string Title; }
 public static List<TopWindow> windows = new List<TopWindow>();
 public static List<TopWindow> TopLevelWindows() { return windows; }
 public static void Add(long handle, uint processId, string title, long owner, bool enabled) {
  TopWindow w = new TopWindow(); w.Handle = (IntPtr)handle; w.ProcessId = processId; w.Title = title; w.Owner = (IntPtr)owner; w.Enabled = enabled;
  windows.Add(w);
 }
}
"@
function Assert($condition, $message) { if (-not $condition) { throw $message } }
# Process.MainWindowHandle as Windows reports it: ApplicationFrameHost owns every UWP frame and names one of them;
# the UWP apps themselves have none.
function Get-Process {
    @([pscustomobject]@{ Id = 500; ProcessName = "chrome"; MainWindowHandle = [IntPtr]80; MainWindowTitle = "notepad tips - Google Chrome" },
      [pscustomobject]@{ Id = 600; ProcessName = "ApplicationFrameHost"; MainWindowHandle = [IntPtr]90; MainWindowTitle = "Calculator" },
      [pscustomobject]@{ Id = 300; ProcessName = "CalculatorApp"; MainWindowHandle = [IntPtr]::Zero; MainWindowTitle = "" },
      [pscustomobject]@{ Id = 700; ProcessName = "SystemSettings"; MainWindowHandle = [IntPtr]::Zero; MainWindowTitle = "" },
      [pscustomobject]@{ Id = 400; ProcessName = "notepad"; MainWindowHandle = [IntPtr]200; MainWindowTitle = "a.txt - Notepad" })
}
function Get-CapturableWindowFrame($hwnd) { [pscustomobject]@{ x = 0; y = 0; width = 400; height = 300 } }
# z-order, topmost first. A browser tab's title mentions notepad. Frames 90 and 95 host the CoreWindows of pids 300 and 700. Notepad's window 200 is disabled
# by the modal dialog 201 it owns.
[OCUWin32]::Add(80, 500, "notepad tips - Google Chrome", 0, $true)
[OCUWin32]::Add(90, 300, "Calculator", 0, $true)
[OCUWin32]::Add(95, 700, "Settings", 0, $true)
[OCUWin32]::Add(201, 400, "Notepad", 200, $true)
[OCUWin32]::Add(200, 400, "a.txt - Notepad", 0, $false)
function Resolve($query) { try { Resolve-App $query } catch { $_.Exception.Message } }

$calc = Resolve "CalculatorApp.exe"
Assert ($calc.Id -eq 300 -and $calc.MainWindowHandle -eq [IntPtr]90) "A UWP app was not found by its own process name: $calc"
$settings = Resolve "Settings"
Assert ($settings.Id -eq 700 -and $settings.MainWindowHandle -eq [IntPtr]95) "A second UWP app was not found by its title: $settings"
Assert ((Resolve "Calculator").Id -eq 300) "A UWP title resolved to ApplicationFrameHost"
foreach ($query in @("notepad", "400", "a.txt")) {
    $notepad = Resolve $query
    Assert ($notepad.Id -eq 400 -and $notepad.MainWindowHandle -eq [IntPtr]201 -and $notepad.MainWindowTitle -eq "Notepad") "'$query' did not resolve to the modal dialog blocking Notepad: $($notepad | ConvertTo-Json -Compress)"
}
@([OCUWin32]::windows | Where-Object { $_.Handle -eq [IntPtr]200 })[0].Enabled = $true
Assert ((Resolve "notepad").MainWindowHandle -eq [IntPtr]200) "An enabled main window lost the root to a dialog it owns"
Assert ((Resolve "nothing") -match 'appNotFound\("nothing"\)') "A missing app was found"
$apps = (List-Apps) -split "`n"
Assert ($apps.Count -eq 4 -and $apps[0] -match "^CalculatorApp .*pid=300, window=Calculator" -and $apps[3] -match "^SystemSettings .*pid=700") "list_apps did not list UWP apps by their own process: $($apps -join ' | ')"
Assert ((Resolve "tips").Id -eq 500) "A window title was not matched"
Write-Output "App resolution: UWP apps by name and title, modal dialog roots, process name before other apps' titles, enabled main window, not found and list_apps passed."

# A dead PID must never select another app whose title happens to be that number.
[OCUWin32]::Add(800, 500, "999999", 0, $true)
Assert ((Resolve "999999") -match 'appNotFound') "Missing PID fell back to another window title"
Assert ((Resolve "*") -match 'appNotFound') "Title query was interpreted as a wildcard"
Assert ((Resolve " ") -match 'must not be empty') "Empty query selected an arbitrary app"
# Main -> first dialog -> nested dialog, where both owners are disabled.
@([OCUWin32]::windows | Where-Object { $_.Handle -eq [IntPtr]200 })[0].Enabled = $false
@([OCUWin32]::windows | Where-Object { $_.Handle -eq [IntPtr]201 })[0].Enabled = $false
[OCUWin32]::Add(202, 400, "Nested", 201, $true)
Assert ((Resolve "notepad").MainWindowHandle -eq [IntPtr]202) "Nested modal root was not followed"
Write-Output "Strict PID, literal title, empty query and nested modal regressions passed."

# Production dispatch must never post to the host frame when it is mapped to another app.
$dispatch=@($ast.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match '\$operation\.tool'})
$script:windowEnabled=$true;$script:hosted=$true
function Resolve-App($query) { [pscustomobject]@{Id=300;ProcessName='hosted';MainWindowHandle=[IntPtr]90;Hosted=$script:hosted;Enabled=$script:windowEnabled} }
function Assert-InputAllowed($process) { }
function Assert-WindowResponds($hwnd,$name) { }
function Find-Element($process,$record) { $null }
function Invoke-TypeText($process,$text) { $false }
function Send-Key { throw 'Unexpected input delivery' }
function Send-MouseClick { throw 'Unexpected input delivery' }
function Send-Text { throw 'Unexpected input delivery' }
foreach($tool in @('click','press_key','type_text')) {
 $operation=[pscustomobject]@{tool=$tool;app='hosted';click_method='app_post';key_method='auto';key='Return';text='fixture'}
 $response=$null;Invoke-Expression $dispatch[0].Extent.Text
 Assert (-not $response.ok -and $response.error -match 'hosted app frame') "Hosted $tool was not refused: $($response|ConvertTo-Json -Compress)"
}
Write-Output 'Hosted posted click/key/text refusal passed.'

$script:windowEnabled=$false;$script:hosted=$false
$operation=[pscustomobject]@{tool='click';app='fixture';click_method='accessibility'}
$response=$null;Invoke-Expression $dispatch[0].Extent.Text
Assert (-not $response.ok -and $response.error -match 'Target window is disabled') 'Disabled unresolved window allowed input'
