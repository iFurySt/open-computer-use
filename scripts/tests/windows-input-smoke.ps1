param([Parameter(Mandatory=$true)][string]$NativePath)
$ErrorActionPreference="Stop"
. (Join-Path $PSScriptRoot "windows-fixture-state.ps1")
if($env:OS -ne "Windows_NT"){throw "Windows desktop required"}
$NativePath=(Resolve-Path -LiteralPath $NativePath).Path
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class InputProbe {
 [StructLayout(LayoutKind.Sequential)] public struct POINT {public int X,Y;}
 [DllImport("user32.dll")] public static extern bool GetPhysicalCursorPos(out POINT p);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
 public static string Cursor(){POINT p;GetPhysicalCursorPos(out p);return p.X+","+p.Y;}
}
"@
$directory=Join-Path ([IO.Path]::GetTempPath()) ("ocu-input-"+[Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile=Join-Path $directory "state.json"
$fixture=$null; $native=$null; $requestId=0; $sequence=0
function Assert($condition,$message){if(-not $condition){throw $message}}
function Wait-For($test,$description){
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 do {try{if(& $test){return}}catch{};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
 try {$details=(State)|ConvertTo-Json -Compress} catch {$details="fixture state unavailable"}
 throw "Timeout: $description; fixture=$details"
}
function State {Read-WindowsFixtureState $stateFile}
function Command($kind){
 $script:sequence++
 Write-WindowsFixtureCommand ($stateFile+".command") (@{sequence=$script:sequence;kind=$kind})
 Wait-For {(State).sequence -eq $script:sequence} "fixture command $kind"
 Start-Sleep -Milliseconds 200
 Assert (-not (State).commandError) ("Fixture command $kind failed: " + (State).commandError)
}
function Stop-Native {
 if($null -ne $script:native -and -not $script:native.HasExited){
  $script:native.StandardInput.Close()
  if(-not $script:native.WaitForExit(3000)){$script:native.Kill();$script:native.WaitForExit()}
 }
}
function Start-Native($enabled){
 Stop-Native
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$NativePath; $start.Arguments="mcp"; $start.UseShellExecute=$false
 $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
 $start.StandardOutputEncoding=[Text.Encoding]::UTF8
 $start.EnvironmentVariables["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"]=$enabled
 $script:native=New-Object Diagnostics.Process; $script:native.StartInfo=$start
 [void]$script:native.Start()
 $null=Request "initialize" @{protocolVersion="2025-03-26";capabilities=@{};clientInfo=@{name="windows-input-smoke";version="1"}}
}
function Request($method,$parameters){
 $script:requestId++
 $native.StandardInput.WriteLine((@{jsonrpc="2.0";id=$script:requestId;method=$method;params=$parameters}|ConvertTo-Json -Depth 20 -Compress))
 $native.StandardInput.Flush()
 $read=$native.StandardOutput.ReadLineAsync()
 Assert ($read.Wait(40000)) "MCP timed out"
 Assert (-not [string]::IsNullOrWhiteSpace($read.Result)) "MCP exited"
 $response=$read.Result|ConvertFrom-Json
 Assert ($response.id -eq $script:requestId -and $null -eq $response.error) "Unexpected RPC response"
 return $response.result
}
function Call($tool,$arguments){$arguments.app=[string]$fixture.Id;Request "tools/call" @{name=$tool;arguments=$arguments}}
function Text($result){($result.content|Where-Object type -eq "text"|ForEach-Object text)-join "`n"}
function OK($result){Assert (-not $result.isError) (Text $result)}
function Observe {
 $result=Call "get_app_state" @{}
 OK $result
 $images=@($result.content|Where-Object type -eq "image")
 Assert ($images.Count -eq 1) (Text $result)
 $bytes=[Convert]::FromBase64String($images[0].data)
 $stream=New-Object IO.MemoryStream(,$bytes)
 $image=[Drawing.Image]::FromStream($stream)
 try {
  $state=State
  Assert ($image.Width -eq $state.width -and $image.Height -eq $state.height) "Capture dimensions differ from independent physical Win32 window bounds"
 }finally{$image.Dispose();$stream.Dispose()}
 return $result
}
function Wheel-Index($result){
 $matches=[regex]::Matches((Text $result),'(?m)^\s*(\d+)\s+[^\r\n]*Wheel target(?:\s|$)')
 Assert ($matches.Count -eq 1) (Text $result)
 return $matches[0].Groups[1].Value
}
try {
 $source=Join-Path $PSScriptRoot "fixtures/WindowsInputFixture.ps1"
 $fixture=Start-Process powershell.exe -ArgumentList @("-NoProfile","-STA","-File","`"$source`"","-StatePath","`"$stateFile`"") -PassThru -RedirectStandardOutput (Join-Path $directory "fixture.out") -RedirectStandardError (Join-Path $directory "fixture.err")
 Wait-For {Test-Path -LiteralPath $stateFile} "fixture startup"
 Wait-For {(Get-Process -Id $fixture.Id).MainWindowHandle -ne [IntPtr]::Zero} "fixture window"
 Command "focus"
 Start-Native "0"
 $full=Observe
 $state=State; $cursor=[InputProbe]::Cursor()
 $denied=Call "click" @{click_method="global";x=$state.buttonX;y=$state.buttonY}
 Assert ($denied.isError -and (Text $denied) -match "requires OPEN_COMPUTER_USE") "Global click gate failed"
 $deniedKey=Call "press_key" @{key="a";key_method="global"}
 Assert ($deniedKey.isError -and (Text $deniedKey) -match "requires OPEN_COMPUTER_USE") "Global key gate failed"
 Assert ([InputProbe]::Cursor() -eq $cursor -and (State).clicks -eq 0) "Denied input changed fixture or cursor"
 Command "reset-scroll"
 $full=Observe
 $before=(State).verticalOffset
 $scroll=Call "scroll" @{element_index=(Wheel-Index $full);direction="down";pages=1}
 OK $scroll
 Wait-For {(State).verticalOffset -gt $before} "default PostMessage scroll fallback"
 Assert ([InputProbe]::Cursor() -eq $cursor) "Default scroll moved system pointer"
 Write-Output "Disabled global gate and actual default window-message scroll fallback passed."

 Start-Native "1"
 Command "focus"
 $null=Observe
 $state=State
 OK (Call "click" @{click_method="global";x=$state.buttonX;y=$state.buttonY})
 Wait-For {(State).clicks -eq 1} "real SendInput button click"
 $cursor=[InputProbe]::Cursor()
 $state=State
 OK (Call "click" @{click_method="app_post";x=$state.inputX;y=$state.inputY})
 Assert ([InputProbe]::Cursor() -eq $cursor) "Explicit app_post moved pointer with gate enabled"
 Command "focus"
 $oldCount=(State).keyCount
 OK (Call "press_key" @{key="ctrl+a";key_method="global"})
 OK (Call "press_key" @{key="z";key_method="global"})
 Wait-For {(State).keyCount -gt $oldCount -and (State).text -eq "z"} "physical combination and text key"
 foreach($key in @(0x11,0x10,0x12,0x5b,0x41,0x5a,1)){Assert ([InputProbe]::GetAsyncKeyState($key) -ge 0) "Physical key/button left held"}
 $invalid=Call "press_key" @{key="ctrl+unmapped";key_method="global"}
 Assert ($invalid.isError -and [InputProbe]::GetAsyncKeyState(0x11) -ge 0) "Invalid key left Ctrl held"
 $null=Observe
 $state=State
 OK (Call "drag" @{from_x=($state.dragX-50);from_y=$state.dragY;to_x=($state.dragX+50);to_y=$state.dragY})
 Wait-For {(State).dragMoves -gt 0} "real dragged mouse movement"
 Assert ([InputProbe]::GetAsyncKeyState(1) -ge 0) "Drag left mouse held"
 foreach($direction in @("down","up","right","left")) {
  Command "reset-scroll"
  $full=Observe; $before=State
  OK (Call "scroll" @{element_index=(Wheel-Index $full);direction=$direction;pages=1})
  $vertical=$direction -in @("up","down"); $increase=$direction -in @("down","right")
  Wait-For {
   $after=State
   $delta=if($vertical){$after.verticalOffset-$before.verticalOffset}else{$after.horizontalOffset-$before.horizontalOffset}
   if($increase){$delta -gt 0}else{$delta -lt 0}
  } "real wheel direction $direction"
 }
 Write-Output "Physical screenshot-coordinate click, explicit app_post, key combination, mouse drag and four wheel directions passed."

 $null=Observe
 $before=State; $cursor=[InputProbe]::Cursor()
 Command "move"
 $stale=Call "click" @{click_method="global";x=$before.buttonX;y=$before.buttonY}
 Assert ($stale.isError -and (Text $stale) -match "geometry changed" -and [InputProbe]::Cursor() -eq $cursor) "Stale geometry was used"
 $null=Observe; $before=State
 Command "cover"
 $cursor=[InputProbe]::Cursor()
 $covered=Call "click" @{click_method="global";x=$before.buttonX;y=$before.buttonY}
 Assert ($covered.isError -and (Text $covered) -match "covered|not foreground" -and [InputProbe]::Cursor() -eq $cursor) ("Occluded target accepted: "+(Text $covered))
 Command "uncover"; Command "focus"; Command "right"
 $null=Observe; $state=State; $clicks=$state.clicks
 OK (Call "click" @{click_method="global";x=$state.buttonX;y=$state.buttonY})
 Wait-For {(State).clicks -eq $clicks+1} "right-edge physical-coordinate click"
 Write-Output ("Moved/occluded target refusal and right-edge capture/click passed. Fixture window DPI="+(State).dpi+"; physical size="+(State).width+"x"+(State).height)
 $full=Observe
 $buttonMatch=[regex]::Matches((Text $full),'(?m)^\s*(\d+)\s+button Physical click target(?:\s|$)')
 Assert ($buttonMatch.Count -eq 1) (Text $full)
 $buttonIndex=$buttonMatch[0].Groups[1].Value
 Command "move-button"
 $cursor=[InputProbe]::Cursor()
 $movedElement=Call "click" @{click_method="global";element_index=$buttonIndex}
 Assert ($movedElement.isError -and (Text $movedElement) -match "Element geometry changed" -and [InputProbe]::Cursor() -eq $cursor) "Moved element used stale frame"
 $full=Observe
 $buttonMatch=[regex]::Match((Text $full),'(?m)^\s*(\d+)\s+button Physical click target(?:\s|$)')
 $buttonIndex=$buttonMatch.Groups[1].Value; $clicks=(State).clicks
 OK (Call "click" @{click_method="global";element_index=$buttonIndex})
 Wait-For {(State).clicks -eq $clicks+1} "verified current element click"
 Command "remove-button"
 $cursor=[InputProbe]::Cursor()
 $gone=Call "click" @{click_method="global";element_index=$buttonIndex}
 Assert ($gone.isError -and (Text $gone) -match "no longer available" -and [InputProbe]::Cursor() -eq $cursor) "Removed element used stale coordinates"
 Write-Output "Moved/removed element refusal and fresh AX recovery passed."
 Command "focus"
 & node (Join-Path $PSScriptRoot "windows-input-js-smoke.mjs") $NativePath ([string]$fixture.Id) $stateFile
 Assert ($LASTEXITCODE -eq 0) "Worker JS physical keyboard smoke failed"
 Write-Output "Windows actual WPF/Win32/native MCP/Worker JS input smoke passed."
}finally{
 Stop-Native
 if($null -ne $fixture -and -not $fixture.HasExited){$fixture.Kill();$fixture.WaitForExit()}
 $errorPath=Join-Path $directory "fixture.err"
 if(Test-Path -LiteralPath $errorPath){Get-Content -LiteralPath $errorPath|Write-Output}
 Remove-Item -LiteralPath $directory -Recurse -Force
}
