param(
 [Parameter(Mandatory=$true)][string]$NativePath,
 [switch]$ExpectOriginal,
 [string]$EvidencePath
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$NativePath=(Resolve-Path -LiteralPath $NativePath).Path
$directory=Join-Path ([IO.Path]::GetTempPath()) ('ocu-child-click-'+[Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile=Join-Path $directory 'state.json'
$fixture=$null; $native=$null; $requestId=0; $sequence=0
function Assert($condition,$message) {if(-not $condition){throw $message}}
function State {
 for($i=0;$i -lt 30;$i++) {
  try {$s=Get-Content -Raw -LiteralPath $stateFile|ConvertFrom-Json;if($null -ne $s.pid){return $s}} catch {}
  Start-Sleep -Milliseconds 100
 }
 throw 'Fixture state unavailable'
}
function Command($kind) {
 $script:sequence++
 [IO.File]::WriteAllText(($stateFile+'.command'),(@{sequence=$script:sequence;kind=$kind}|ConvertTo-Json -Compress))
 for($i=0;$i -lt 50;$i++) {Start-Sleep -Milliseconds 100;if((State).sequence -eq $script:sequence){return}}
 throw "Fixture command timed out: $kind"
}
function Request($method,$parameters) {
 $script:requestId++
 $native.StandardInput.WriteLine((@{jsonrpc='2.0';id=$script:requestId;method=$method;params=$parameters}|ConvertTo-Json -Depth 20 -Compress))
 $native.StandardInput.Flush()
 $read=$native.StandardOutput.ReadLineAsync()
 Assert ($read.Wait(40000)) 'MCP timed out'
 $response=$read.Result|ConvertFrom-Json
 Assert ($response.id -eq $script:requestId -and $null -eq $response.error) 'Unexpected RPC response'
 return $response.result
}
function Call($tool,$arguments) {$arguments.app=[string]$fixture.Id;Request 'tools/call' @{name=$tool;arguments=$arguments}}
function Text($result) {($result.content|Where-Object type -eq 'text'|ForEach-Object text)-join "`n"}
function OK($result) {Assert (-not $result.isError) (Text $result)}
function Pixel($result) {
 OK $result
 $images=@($result.content|Where-Object type -eq 'image')
 Assert ($images.Count -eq 1) (Text $result)
 $stream=New-Object IO.MemoryStream(,[Convert]::FromBase64String($images[0].data))
 $image=[Drawing.Bitmap]::FromStream($stream)
 try {$c=$image.GetPixel([int]($image.Width/2),$image.Height-100);return "$($c.R),$($c.G),$($c.B)"}
 finally {$image.Dispose();$stream.Dispose()}
}
function Click($kind='button',$method='app_post',$button='left') {
 $s=State
 Call 'click' @{x=$s.($kind+'X');y=$s.($kind+'Y');click_method=$method;mouse_button=$button;click_count=1}
}
try {
 $fixtureSource=Join-Path $PSScriptRoot 'fixtures/WindowsTargetFixture.ps1'
 $fixture=Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$fixtureSource`"",'-StatePath',"`"$stateFile`"") -PassThru -RedirectStandardOutput (Join-Path $directory 'fixture.out') -RedirectStandardError (Join-Path $directory 'fixture.err')
 for($i=0;$i -lt 100 -and -not (Test-Path $stateFile);$i++){Start-Sleep -Milliseconds 100}
 $s=State;Write-Output "Fixture DPI=$($s.dpi), original=$ExpectOriginal"
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$NativePath; $start.Arguments='mcp'; $start.UseShellExecute=$false
 $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
 $start.StandardOutputEncoding=[Text.Encoding]::UTF8
 $start.EnvironmentVariables['OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS']=''
 $native=New-Object Diagnostics.Process; $native.StartInfo=$start;[void]$native.Start()
 $null=Request 'initialize' @{protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='windows-target-regression';version='1'}}
 $native.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');$native.StandardInput.Flush()
 OK (Call 'get_app_state' @{})
 $before=State;OK (Click);Start-Sleep -Milliseconds 200
 $expected=if($ExpectOriginal){0}else{1}
 Assert ((State).leftUps -eq $before.leftUps+$expected) 'Child button message delivery mismatch'
 Write-Output "Posted child button: MouseUp delta=$expected"
 Command 'cover'
 $observed=Call 'get_app_state' @{}
 $expectedPixel=if($ExpectOriginal){'220,30,120'}else{'20,80,180'}
 $actualPixel=Pixel $observed
 Assert ($actualPixel -eq $expectedPixel) "Covered pixel mismatch: $actualPixel"
 Write-Output "Covered screenshot pixel=$actualPixel"
 if ($EvidencePath) {
  # Save only the fixture's client area, excluding desktop pixels around the
  # rounded window borders. This opt-in artifact is separate from test logs.
  $imageBlock=@($observed.content|Where-Object type -eq 'image')[0]
  $stream=New-Object IO.MemoryStream(,[Convert]::FromBase64String($imageBlock.data))
  $image=[Drawing.Bitmap]::FromStream($stream)
  $cropped=$null
  try {
   $rect=New-Object Drawing.Rectangle(16,60,($image.Width-32),($image.Height-76))
   $cropped=$image.Clone($rect,[Drawing.Imaging.PixelFormat]::Format24bppRgb)
   $cropped.Save([IO.Path]::GetFullPath($EvidencePath),[Drawing.Imaging.ImageFormat]::Png)
  } finally {
   if($null -ne $cropped){$cropped.Dispose()}
   $image.Dispose();$stream.Dispose()
  }
  Write-Output 'Saved cropped fixture screenshot evidence.'
 }

 if(-not $ExpectOriginal) {
  foreach($case in @(@('button','app_post','left','leftUps'),@('button','auto','left','clicks'),@('button','app_post','right','rightClicks'),@('panel','app_post','left','panelClicks'))) {
   $before=State;OK (Click $case[0] $case[1] $case[2]);Start-Sleep -Milliseconds 200;$after=State
   Assert ($after.($case[3]) -eq $before.($case[3])+1) "Counter did not increment: $case"
   # A person may switch windows during the multi-second MCP request. Record both
   # observations; fault tests reject any foreground/pointer API in posted input.
   Write-Output "Covered $case passed; foreground unchanged=$($before.foreground -eq $after.foreground); cursor unchanged=$($before.cursorX -eq $after.cursorX -and $before.cursorY -eq $after.cursorY)"
  }
  $r=Call 'click' @{x=-10;y=-10;click_method='app_post'}
  Assert ($r.isError) 'Out-of-window point was not refused'
  $observed=Call 'get_app_state' @{}
  $match=[regex]::Match((Text $observed),'(?m)^\s*(\d+) [^\r\n]*Count fixture clicks')
  Assert $match.Success 'Fixture button index missing'
  Command 'move-button'
  $r=Call 'click' @{element_index=$match.Groups[1].Value;click_method='app_post'}
  Assert ($r.isError -and (Text $r) -match 'geometry changed') 'Stale element geometry not refused'
  OK (Call 'get_app_state' @{})
  Command 'disable';$r=Click;Assert ($r.isError -and (Text $r) -match 'disabled') 'Disabled control not refused';Command 'enable'
  Command 'move';$r=Click;Assert ($r.isError -and (Text $r) -match 'geometry changed') 'Stale geometry not refused'
  Command 'minimize';$r=Call 'get_app_state' @{};OK $r
  Assert (@($r.content|Where-Object type -eq 'image').Count -eq 0) 'Minimized screenshot should be unavailable'
  Write-Output 'Disabled child, out-of-window point, stale window/element geometry and minimized screenshot guards passed'
 }
 Write-Output 'PASS'
} finally {
 if($null -ne $native -and -not $native.HasExited){$native.StandardInput.Close();if(-not $native.WaitForExit(3000)){$native.Kill()}}
 if($null -ne $fixture -and -not $fixture.HasExited){Stop-Process -Id $fixture.Id -Force;$fixture.WaitForExit()}
 Remove-Item -Recurse -Force -LiteralPath $directory -ErrorAction SilentlyContinue
}
