param([Parameter(Mandatory=$true)][string]$RuntimePath)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($RuntimePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$functions=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Send-MouseClick','ConvertTo-LParam')},$true)
if($functions.Count -ne 2){throw 'Production click functions missing'}
foreach($f in $functions){Invoke-Expression $f.Extent.Text}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class OCUWin32 {
 public struct POINT {public int X,Y;}
 public static List<string> events=new List<string>();
 public static uint failMessage;
 public static int conversions, moveOnConversion;
 public static IntPtr ClickTarget(IntPtr root,int x,int y){return (IntPtr)43;}
 public static bool ScreenToClient(IntPtr target,ref POINT p){conversions++;p.X-=100;p.Y-=200;if(moveOnConversion>0 && conversions>=moveOnConversion)p.X-=10;return true;}
 public static bool PostMessage(IntPtr target,uint message,IntPtr w,IntPtr l){events.Add(target+":"+message+":"+l);return message!=failMessage;}
}
'@
$WM_MOUSEMOVE=512;$WM_LBUTTONDOWN=513;$WM_LBUTTONUP=514
$WM_RBUTTONDOWN=516;$WM_RBUTTONUP=517;$WM_MBUTTONDOWN=519;$WM_MBUTTONUP=520
$script:stale=$false
function Assert-CurrentWindowBounds($hwnd,$bounds){if($script:stale){throw 'geometry changed'}}
function Start-Sleep {param($Milliseconds) if($script:interrupt -and $Milliseconds -eq 35){throw 'interrupted after down'}}
function Assert($ok,$message){if(-not $ok){throw $message}}
function Refuses($action,$pattern){$message='';try{& $action}catch{$message=$_.Exception.Message};Assert ($message -match $pattern) "Expected $pattern, got $message"}
function Reset {[OCUWin32]::events.Clear();[OCUWin32]::failMessage=0;[OCUWin32]::conversions=0;[OCUWin32]::moveOnConversion=0;$script:stale=$false;$script:interrupt=$false}
Reset
Send-MouseClick 42 110 220 left 1 @{}
Assert (([OCUWin32]::events -join ',') -eq '43:512:1310730,43:513:1310730,43:514:1310730') 'Click was not routed to child-local coordinates'
Reset
$script:stale=$true
Refuses {Send-MouseClick 42 110 220 left 1 @{}} 'geometry changed'
Assert ([OCUWin32]::events.Count -eq 0) 'Stale target received messages'
Reset
Refuses {Send-MouseClick 42 110 220 left 0 @{}} 'between 1 and 3'
Refuses {Send-MouseClick 42 110 220 invalid 1 @{}} 'Unsupported'
Assert ([OCUWin32]::events.Count -eq 0) 'Invalid click received messages'
foreach($failure in @(512,513,514)) {
 Reset;[OCUWin32]::failMessage=$failure
 Refuses {Send-MouseClick 42 110 220 left 1 @{}} 'delivery failed'
 if($failure -eq 513){Assert ([OCUWin32]::events[-1] -match ':514:') 'Failed down did not attempt release'}
}
Reset
[OCUWin32]::moveOnConversion=2
Refuses {Send-MouseClick 42 110 220 left 1 @{}} 'geometry changed'
Assert ([OCUWin32]::events.Count -eq 0) 'Moved child received a click at stale local coordinates'
Reset
[OCUWin32]::moveOnConversion=3
Refuses {Send-MouseClick 42 110 220 left 2 @{}} 'geometry changed'
Assert ([OCUWin32]::events.Count -eq 3) 'Second click was sent after the child moved'
Reset
$script:interrupt=$true
Refuses {Send-MouseClick 42 110 220 left 1 @{}} 'interrupted after down'
Assert ([OCUWin32]::events[-1] -match ':514:') 'Interrupted down did not release mouse'
Write-Output 'PASS production posted click: child coordinates, moved-child/invalid refusal, delivery failures and interrupted release cleanup'
