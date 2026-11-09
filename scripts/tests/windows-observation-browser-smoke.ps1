param([Parameter(Mandatory=$true)][string]$NativePath)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows desktop required' }
$directory=Join-Path ([IO.Path]::GetTempPath()) ('ocu-browser-selection-'+[Guid]::NewGuid())
[void](New-Item -ItemType Directory $directory)
$profile=Join-Path $directory 'profile'
$title='OCU Selection '+[Guid]::NewGuid().ToString('N')
$process=$null
function Assert($condition,$message) {if(-not $condition){throw $message}}
function Invoke-Native($calls) {
    $file=Join-Path $directory 'calls.json'
    [IO.File]::WriteAllText($file,(ConvertTo-Json -InputObject @($calls) -Depth 15),[Text.UTF8Encoding]::new($false))
    $output=& $NativePath call --calls-file $file 2> (Join-Path $directory 'native.err')
    Assert ($LASTEXITCODE -eq 0) (($output -join "`n") + (Get-Content (Join-Path $directory 'native.err') -Raw))
    return ($output -join "`n" | ConvertFrom-Json)
}
try {
    $edge=@("${env:ProgramFiles(x86)}/Microsoft/Edge/Application/msedge.exe", "$env:ProgramFiles/Microsoft/Edge/Application/msedge.exe") | Where-Object {Test-Path $_} | Select-Object -First 1
    Assert ($null -ne $edge) 'Edge required for the real Chromium regression'
    $html=Join-Path $directory 'fixture.html'
    [IO.File]::WriteAllText($html,"<html><title>$title</title><body><input id='entry' aria-label='Selection input' value='ordinary browser text'><button onclick=`"document.title='$title clicked'`">Selection action</button><script>entry.focus();entry.select();</script></body></html>")
    $process=Start-Process $edge -ArgumentList @("--user-data-dir=`"$profile`"",'--no-first-run','--disable-sync','--force-renderer-accessibility','--new-window',([Uri]$html).AbsoluteUri) -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do {
        $target=Get-Process msedge -ErrorAction SilentlyContinue | Where-Object {$_.MainWindowTitle -like "*$title*" -and $_.MainWindowHandle -ne [IntPtr]::Zero} | Select-Object -First 1
        if($null -ne $target){break}
        Start-Sleep -Milliseconds 100
    } while([DateTime]::UtcNow -lt $deadline)
    Assert ($null -ne $target) 'Isolated Edge window did not appear'
    $app=[string]$target.Id
    # Keep one native session for snapshot indexes and the actual action/read-back.
    # First discover the button index using a read-only process; the next batch
    # observes again, which preserves deterministic indexes on this fixed page.
    $read=Invoke-Native @(@{tool='get_app_state';args=@{app=$app;include_screenshot=$false}})
    $result=$read[0].result
    $text=($result.content | Where-Object type -eq 'text' | ForEach-Object text) -join "`n"
    Assert (-not $result.isError -and $text -match 'Selection input') 'Chromium AX tree missing'
    $match=[regex]::Match($text,'(?m)^\s*(\d+)\s+[^\r\n]*?Selection action(?:\s|$)')
    Assert $match.Success 'Chromium test button missing'
    $responses=Invoke-Native @(
        @{tool='get_app_state';args=@{app=$app;include_screenshot=$false}},
        @{tool='click';args=@{app=$app;element_index=$match.Groups[1].Value}},
        @{tool='get_app_state';args=@{app=$app;include_screenshot=$false}}
    )
    foreach($response in $responses){Assert (-not $response.result.isError) 'Chromium observation/action failed'}
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do { $target.Refresh(); if($target.MainWindowTitle -like '*clicked*'){break}; Start-Sleep -Milliseconds 50 } while([DateTime]::UtcNow -lt $deadline)
    Assert ($target.MainWindowTitle -like '*clicked*') 'Click returned without performing the browser action'
    Write-Output "Real Edge $($target.MainModule.FileVersionInfo.ProductVersion): AX-only snapshot, click and follow-up snapshot passed. Original Opera/Electron access violation is reporter evidence, not claimed reproduced by this Edge test."
} finally {
    if ($null -ne $process) {
        # Only processes belonging to the disposable profile, never the user's browser.
        Get-CimInstance Win32_Process -Filter "name = 'msedge.exe'" | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($profile)} | ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
    }
    Start-Sleep -Milliseconds 500
    Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue
}
