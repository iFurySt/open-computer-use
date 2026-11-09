param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Where production press_key (auto) and type_text send keyboard input, run over Win32/UIA doubles. Runs under pwsh
# on any OS; whether a given toolkit accepts the posted messages is a desktop question.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Send-Key", "Get-VirtualKey", "Get-PostedKeyTarget", "Send-Text", "Invoke-TypeText", "Test-EditWindowClass",
    "Send-TextToEditHandle", "Find-TextEntryElement", "Find-TextEntryWindowHandle", "Test-TextWindowHandleCandidate",
    "Get-NativeWindowHandle", "Get-CurrentPatternOrNull", "Get-ElementControlTypeName", "Get-ElementString", "Get-ElementInt64",
    "Test-EnvFlagEnabled")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production keyboard functions missing: $($names | Where-Object { $_ -notin @($functions | ForEach-Object Name) })" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class OCUWin32 {
 public static IntPtr focus = IntPtr.Zero;
 public static string focusClass = "Edit";
 public static int style;
 public static bool postWorks = true;
 public static List<string> events = new List<string>();
 public static IntPtr FocusedWindow(IntPtr w) { return focus; }
 public static bool IsChild(IntPtr parent, IntPtr child) { return parent == (IntPtr)42 && (child == (IntPtr)44 || child == (IntPtr)45); }
 public static string ClassName(IntPtr w) { return w == focus ? focusClass : "Edit"; }
 public static int GetWindowLong(IntPtr w, int index) { return style; }
 public static bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l) { events.Add("post:" + h + ":" + m + ":" + w); return postWorks; }
 public static IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l) { events.Add("send:" + h + ":" + m); return IntPtr.Zero; }
 public static IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l) { events.Add("text:" + h + ":" + l); return IntPtr.Zero; }
}
namespace Windows.Automation {
 public static class AutomationElement { public static object FocusedElement; }
 public static class ValuePattern { public static string Pattern = "Value"; }
}
"@
$WM_KEYDOWN = 0x0100; $WM_KEYUP = 0x0101; $WM_CHAR = 0x0102; $WM_SETTEXT = 0x000C
$EM_SETSEL = 0x00B1; $EM_REPLACESEL = 0x00C2; $GWL_STYLE = -16; $ES_READONLY = 0x0800
function Start-Sleep { param($Milliseconds) if ($script:interruptSleep) { throw "interrupted" } }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Refuses($call, $pattern) {
    $failure = $null
    try { & $call } catch { $failure = $_.Exception.Message }
    Assert ($null -ne $failure -and $failure -match $pattern) "Expected refusal '$pattern', got '$failure'"
}
function Field($handle, $className = "Edit") {
    $field = [pscustomobject]@{ Current = [pscustomobject]@{ ProcessId = 7; NativeWindowHandle = $handle; ClassName = $className; ControlType = [pscustomobject]@{ ProgrammaticName = "ControlType.Edit" } } }
    $field | Add-Member ScriptMethod GetCurrentPattern { param($pattern) [pscustomobject]@{ Current = [pscustomobject]@{ IsReadOnly = $false; Value = "" } } }
    return $field
}
function Get-MainElement($process) { "window" }
function Get-AllElements($root) { $script:fields }
function Get-ElementValue($element) { "" }
function Reset($focus = 0, $fields = @((Field 44), (Field 45))) {
    [OCUWin32]::focus = [IntPtr]$focus; [OCUWin32]::focusClass = "Edit"; [OCUWin32]::style = 0; [OCUWin32]::postWorks = $true
    $script:interruptSleep = $false
    [OCUWin32]::events.Clear()
    [Windows.Automation.AutomationElement]::FocusedElement = $null
    $script:fields = $fields
}
function Events { [OCUWin32]::events -join "," }
$process = [pscustomobject]@{ Id = 7; ProcessName = "fixture"; MainWindowHandle = [IntPtr]42 }

# press_key: posted keys reach the focused control inside the window, else the window as before.
Reset 44; Send-Key 42 "Return" "auto"
Assert ((Events) -eq "post:44:256:13,post:44:257:13") "Return did not reach the focused control: $(Events)"
Reset 0; Send-Key 42 "Return" "auto"
Assert ((Events) -eq "post:42:256:13,post:42:257:13") "Without a focused control the key did not go to the window: $(Events)"
Reset 99; Send-Key 42 "a" "auto"
Assert ((Events) -eq "post:42:256:65,post:42:257:65") "Focus in another window drew the key away: $(Events)"
Reset 44; Refuses { Send-Key 42 "ctrl+a" "auto" } "cannot carry modifier keys"
Refuses { Send-Key 42 "shift+Tab" "auto" } "cannot carry modifier keys"
Assert ((Events) -eq "") "A refused chord posted keys: $(Events)"
Reset 44; [OCUWin32]::postWorks = $false
Refuses { Send-Key 42 "a" "auto" } "key delivery failed"
Refuses { Send-Text 44 "a" } "character delivery failed"
Write-Output "press_key: focused control, window fallback, foreign focus, refused chords and failed delivery passed."

# type_text: the focused edit control first, then a field only when it is the only one.
Reset 45; Invoke-TypeText $process "hi" | Out-Null
Assert ((Events) -eq "send:45:177,text:45:hi") "Text did not go to the focused second field: $(Events)"
Reset 45; [OCUWin32]::focusClass = "WindowsForms10.EDIT.app.0.141b42a_r6_ad1"; Invoke-TypeText $process "hi" | Out-Null
Assert ((Events) -eq "send:45:177,text:45:hi") "A focused WinForms edit was not typed into: $(Events)"
Reset 45; [OCUWin32]::style = 0x0800
Refuses { Invoke-TypeText $process "hi" } "read-only"
Reset 0; Refuses { Invoke-TypeText $process "hi" } "2 text fields and none has keyboard focus"
Assert ((Events) -eq "") "Text was sent to a guessed field: $(Events)"
Reset 44 @((Field 45)); [OCUWin32]::focusClass = "Button"; Invoke-TypeText $process "hi" | Out-Null
Assert ((Events) -eq "send:45:177,text:45:hi") "The only field was not typed into while a button had focus: $(Events)"
Reset 0 @((Field 44)); Invoke-TypeText $process "hi" | Out-Null
Assert ((Events) -eq "send:44:177,text:44:hi") "The only field was not typed into in the background: $(Events)"
foreach ($class in @("Edit", "RICHEDIT50W", "RichEdit20W", "WindowsForms10.RichEdit20W.app.0.1", "WindowsForms10.EDIT.app.0.141b42a_r6_ad1")) { Assert (Test-EditWindowClass $class) "$class not taken for an edit control" }
foreach ($class in @("Scintilla", "HwndWrapper[app;;1]", "EditorPane", "Button")) { Assert (-not (Test-EditWindowClass $class)) "$class taken for an edit control" }
Write-Output "type_text: focused field, WinForms edit, read-only, several unfocused fields refused, single field and edit classes passed."

Reset 0
$readonly = Field 0 'HwndWrapper'
$readonly | Add-Member -Force ScriptMethod GetCurrentPattern { param($pattern) [pscustomobject]@{Current=[pscustomobject]@{IsReadOnly=$true;Value='fixed'}} }
[Windows.Automation.AutomationElement]::FocusedElement = $readonly
Refuses { Invoke-TypeText $process 'must-not-write' } 'read-only'
Assert ((Events) -eq '') 'Read-only UIA focus redirected to another writable field'
Reset 0
Assert ((Find-TextEntryWindowHandle $process (Field 0 'HwndWrapper')) -eq [IntPtr]::Zero) 'UIA target without HWND redirected to another child'
Reset 44; $script:interruptSleep = $true
Refuses { Send-Key 42 'Return' 'auto' } 'interrupted'
Assert ((Events) -eq 'post:44:256:13,post:44:257:13') 'Interrupted posted press missed key-up'
Write-Output 'Readonly UIA focus, no HWND retarget and interrupted key cleanup passed.'
