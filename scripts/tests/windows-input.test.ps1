param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Run production control flow with a Win32 fault-injection double. Desktop
# acceptance is a separate native-MCP test, not inferred from these doubles.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Test-EnvFlagEnabled", "Test-GlobalPointerFallbackEnabled", "Assert-GlobalInputTarget", "Assert-CurrentWindowBounds", "Assert-GlobalPointerTarget", "Send-GlobalMouseMove", "Send-GlobalMouseClick", "Send-Drag", "Send-Scroll", "Send-Key", "Get-PostedKeyTarget", "Get-VirtualKey", "ConvertTo-LParam", "ConvertTo-WheelWParam", "Resolve-GlobalElementPoint", "Same-RuntimeId", "Get-ScreenPoint")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production input functions missing" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
public static class OCUWin32 {
 public struct POINT { public int X,Y; }
 public static IntPtr foreground = (IntPtr)42, root = (IntPtr)42;
 public static bool focusWorks = true, moveWorks = true, held = false;
 public static int moves, failMoveAt, failKey, failKeyUp, loseFocusAfterKey, keyUps;
 public static long lastLParam;
 public static bool postWorks=true;
 public static List<string> events = new List<string>();
 public static IntPtr GetForegroundWindow() { return foreground; }
 public static bool SetForegroundWindow(IntPtr w) { if(focusWorks) foreground=w; return focusWorks; }
 public static IntPtr WindowFromPoint(POINT p) { return (IntPtr)43; }
 public static IntPtr GetAncestor(IntPtr w,uint f) { return root; }
 public static short GetAsyncKeyState(int k) { return held ? (short)-32768 : (short)0; }
 public static bool SetCursorPos(int x,int y) { moves++; if(failMoveAt==moves) throw new Exception("move interrupted"); return moveWorks; }
 public static void MouseInput(uint flags,int data) { events.Add("mouse:"+flags+":"+data); }
 public static void KeyInput(int key,bool up) { events.Add("key:"+key+":"+up); if(up)keyUps++; if(!up&&key==loseFocusAfterKey)foreground=(IntPtr)99; if(up&&key==failKeyUp)throw new Exception("key release interrupted"); if(!up&&key==failKey)throw new Exception("key interrupted"); }
 public static bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l) { events.Add("post:"+m); lastLParam=l.ToInt64(); return postWorks; }
 public static IntPtr FocusedWindow(IntPtr w) { return IntPtr.Zero; }
 public static bool IsChild(IntPtr p,IntPtr c) { return false; }
}
"@
$MOUSEEVENTF_LEFTDOWN=2; $MOUSEEVENTF_LEFTUP=4
$MOUSEEVENTF_RIGHTDOWN=8; $MOUSEEVENTF_RIGHTUP=16
$MOUSEEVENTF_MIDDLEDOWN=32; $MOUSEEVENTF_MIDDLEUP=64
$MOUSEEVENTF_WHEEL=2048; $MOUSEEVENTF_HWHEEL=4096
$WM_KEYDOWN=256; $WM_KEYUP=257
$bounds = [pscustomobject]@{x=10;y=20;width=400;height=300}
$script:currentBounds = $bounds
function Get-CapturableWindowFrame($hwnd) { $script:currentBounds }
function Assert-UsableWindowBounds($frame) { if ($null -eq $frame) { throw "no bounds" } }
function Start-Sleep { param($Milliseconds) }
function Assert($condition,$message) { if(-not $condition) {throw $message} }
function Refuses($call,$pattern) {
 $failure=$null
 try { & $call } catch { $failure=$_.Exception.Message }
 Assert ($null -ne $failure -and $failure -match $pattern) "Expected refusal '$pattern', got '$failure'"
}
function Reset {
 $env:OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS="1"
 [OCUWin32]::foreground=[IntPtr]42; [OCUWin32]::root=[IntPtr]42
 [OCUWin32]::focusWorks=$true; [OCUWin32]::moveWorks=$true; [OCUWin32]::held=$false
 [OCUWin32]::moves=0; [OCUWin32]::failMoveAt=0; [OCUWin32]::failKey=0; [OCUWin32]::failKeyUp=0; [OCUWin32]::loseFocusAfterKey=0; [OCUWin32]::keyUps=0
 [OCUWin32]::events.Clear(); [OCUWin32]::postWorks=$true; $script:currentBounds=$bounds
}
Reset
$env:OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=""
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "requires"
Assert ([OCUWin32]::moves -eq 0 -and [OCUWin32]::events.Count -eq 0) "Gate moved pointer or sent input"
Reset
Refuses { Send-GlobalMouseClick 42 30 40 "unknown" 1 $bounds } "Unsupported global mouse button"
Refuses { Send-GlobalMouseClick 42 30 40 "left" 10000 $bounds } "between 1 and 3"
Assert ([OCUWin32]::moves -eq 0 -and [OCUWin32]::events.Count -eq 0) "Invalid physical click sent input"
Reset
[OCUWin32]::foreground=[IntPtr]99; [OCUWin32]::focusWorks=$false
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "not foreground"
Refuses { Send-Drag 42 30 40 50 60 $bounds } "not foreground"
Refuses { Send-Scroll 42 30 40 "down" 1 $bounds } "not foreground"
Refuses { Send-Key 42 "ctrl+a" "global" } "not foreground"
Assert ([OCUWin32]::moves -eq 0 -and [OCUWin32]::events.Count -eq 0) "Focus failure sent input (including Alt)"
Reset
[OCUWin32]::root=[IntPtr]99
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "covered"
Assert ([OCUWin32]::moves -eq 0) "Covered target moved cursor"
Reset
$script:currentBounds=[pscustomobject]@{x=50;y=20;width=400;height=300}
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "geometry changed"
Assert ([OCUWin32]::moves -eq 0) "Stale geometry moved cursor"
Reset
Refuses { Send-GlobalMouseClick 42 999 40 "left" 1 $bounds } "outside"
Assert ([OCUWin32]::moves -eq 0) "Out of bounds moved cursor"
Reset
[OCUWin32]::moveWorks=$false
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "SetCursorPos failed"
Assert ([OCUWin32]::events.Count -eq 0) "Failed pointer move clicked"
Reset
[OCUWin32]::failMoveAt=2
Refuses { Send-Drag 42 30 40 50 60 $bounds } "move interrupted"
Assert (([OCUWin32]::events -join ",") -eq "mouse:2:0,mouse:4:0") "Interrupted drag did not release mouse"
Reset
Refuses { Send-Key 42 "ctrl+unmapped" "global" } "Unsupported key"
Refuses { Send-Key 42 "typo+a" "global" } "Unsupported key modifier"
Assert ([OCUWin32]::events.Count -eq 0) "Invalid chord pressed a modifier"
Reset
[OCUWin32]::failKey=65
Refuses { Send-Key 42 "ctrl+shift+a" "global" } "key interrupted"
Assert (([OCUWin32]::events -join ",") -eq "key:17:False,key:16:False,key:65:False,key:65:True,key:16:True,key:17:True") "Interrupted chord did not release all keys in reverse order"
Reset
[OCUWin32]::failKeyUp=65
Refuses { Send-Key 42 "ctrl+shift+a" "global" } "Global key release failed"
Assert ([OCUWin32]::keyUps -eq 3) "One failed key release prevented remaining modifier cleanup"
Reset
[OCUWin32]::loseFocusAfterKey=17
Refuses { Send-Key 42 "ctrl+a" "global" } "not foreground"
Assert (([OCUWin32]::events -join ",") -eq "key:17:False,key:17:True") "Foreground loss sent the main key or left Ctrl held"
Reset
[OCUWin32]::held=$true
Refuses { Send-Key 42 "ctrl+a" "global" } "already held"
Refuses { Send-GlobalMouseClick 42 30 40 "left" 1 $bounds } "already held"
Assert ([OCUWin32]::events.Count -eq 0) "Already held input was modified"
Reset
$env:OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=""
Send-Scroll 42 310 220 "down" 1 $bounds
Assert ([OCUWin32]::lastLParam -eq (ConvertTo-LParam 310 220).ToInt64() -and [OCUWin32]::moves -eq 0) "Default wheel did not retain screen coordinates"
[OCUWin32]::postWorks=$false
Refuses { Send-Scroll 42 310 220 "up" 1 $bounds } "PostMessage wheel delivery failed"
Reset
Refuses { Send-Key 42 "ctrl+a" "auto" } "cannot carry modifier keys"
Send-Key 42 "a" "auto"
Assert ([OCUWin32]::keyUps -eq 0 -and ([OCUWin32]::events -join ",") -eq "post:256,post:257") "Auto key delivery became global"
Reset
Send-Scroll 42 30 40 "left" 1 $bounds
Send-Scroll 42 30 40 "right" 1 $bounds
Send-Scroll 42 30 40 "up" 1 $bounds
Send-Scroll 42 30 40 "down" 1 $bounds
Assert (([OCUWin32]::events -join ",") -eq "mouse:4096:-120,mouse:4096:120,mouse:2048:120,mouse:2048:-120") "Wheel direction mismatch"
Reset
$record=[pscustomobject]@{runtimeId=@(1,2);frame=[pscustomobject]@{x=20;y=30;width=40;height=20}}
$element=New-Object PSObject
$element | Add-Member ScriptMethod GetRuntimeId { @(1,2) }
$script:elementFrame=$record.frame
function Get-ElementFrame($element,$bounds) { $script:elementFrame }
Refuses { Resolve-GlobalElementPoint $null $record $bounds } "no longer available"
$wrong=New-Object PSObject
$wrong | Add-Member ScriptMethod GetRuntimeId { @(1,3) }
Refuses { Resolve-GlobalElementPoint $wrong $record $bounds } "no longer available"
$script:elementFrame=[pscustomobject]@{x=50;y=30;width=40;height=20}
Refuses { Resolve-GlobalElementPoint $element $record $bounds } "Element geometry changed"
$script:elementFrame=$record.frame
$point=Resolve-GlobalElementPoint $element $record $bounds
Assert ($point.x -eq 50 -and $point.y -eq 60 -and [OCUWin32]::events.Count -eq 0) "Element point did not use the verified current frame"
Reset
Send-GlobalMouseClick 42 30 40 "right" 2 $bounds
Assert (([OCUWin32]::events -join ",") -eq "mouse:8:0,mouse:16:0,mouse:8:0,mouse:16:0") "Physical click count/button mismatch"
Write-Output "Windows production input control flow: gates, focus/hit/geometry refusal, cleanup, explicit keyboard routing and wheel directions passed (Win32 fault doubles)."
