param([Parameter(Mandatory = $true)][string]$NativePath)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "windows-fixture-state.ps1")
if ($env:OS -ne "Windows_NT") { throw "Windows desktop required" }
$NativePath = (Resolve-Path -LiteralPath $NativePath).Path
$directory = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-observation-" + [Guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $directory)
$stateFile = Join-Path $directory "state.json"
$fixture = $null
$native = $null
$requestId = 0

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Wait-For($test, $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($null -ne $fixture -and $fixture.HasExited) { throw "WPF fixture exited before $description" }
        try { if (& $test) { return } } catch { }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout: $description"
}
function Read-State { Read-WindowsFixtureState $stateFile }
function Send-Request($method, $parameters) {
    $script:requestId += 1
    $message = @{ jsonrpc = "2.0"; id = $script:requestId; method = $method; params = $parameters }
    $native.StandardInput.WriteLine(($message | ConvertTo-Json -Depth 20 -Compress))
    $native.StandardInput.Flush()
    $read = $native.StandardOutput.ReadLineAsync()
    Assert ($read.Wait(40000)) "MCP timed out"
    Assert (-not [string]::IsNullOrWhiteSpace($read.Result)) "MCP exited"
    $response = $read.Result | ConvertFrom-Json
    Assert ($response.id -eq $script:requestId -and $null -eq $response.error) "Unexpected RPC response"
    return $response.result
}
function Call-Tool($tool, $arguments) {
    if (-not $arguments.ContainsKey("app")) { $arguments.app = [string]$fixture.Id }
    Send-Request "tools/call" @{ name = $tool; arguments = $arguments }
}
function Text($result) { ($result.content | Where-Object type -eq "text" | ForEach-Object text) -join "`n" }

try {
    $fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsSetValueFixture.ps1"
    $fixture = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$stateFile`"") -PassThru -RedirectStandardOutput (Join-Path $directory "fixture.out") -RedirectStandardError (Join-Path $directory "fixture.err")
    Wait-For { Test-Path -LiteralPath $stateFile } "WPF startup"
    Wait-For { (Get-Process -Id $fixture.Id).MainWindowHandle -ne [IntPtr]::Zero } "visible WPF main window"
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $NativePath
    $start.Arguments = "mcp"
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $native = New-Object System.Diagnostics.Process
    $native.StartInfo = $start
    [void]$native.Start()
    $null = Send-Request "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-set-value-smoke"; version = "1" } }
    foreach ($case in @(
        @{mode='normal';value=" `t中文🙂`n"}, @{mode='normal';value=''},
        @{mode='normal';value='same'}, @{mode='normal';value='same'},
        @{mode='delay';value='delayed'}, @{mode='ignore';value='new';error=$true},
        @{mode='trim';value=' padded ';error=$true}, @{mode='numeric';value='0015';error=$true}
    )) {
        $tree=Call-Tool 'get_app_state' @{include_screenshot=$false}
        Assert (-not $tree.isError) (Text $tree)
        $match=[regex]::Match((Text $tree),('(?m)^\s*(\d+)\s+edit Value '+$case.mode+'(?:\s|$)'))
        Assert ($match.Success) (Text $tree)
        $before=(Read-State).($case.mode).writes
        $result=Call-Tool 'set_value' @{element_index=$match.Groups[1].Value;value=$case.value}
        Assert ([bool]$result.isError -eq [bool]$case.error) (Text $result)
        if($case.error){Assert ((Text $result) -match 'could not verify') (Text $result)}
        else{Wait-For {[string]::Equals((Read-State).($case.mode).value,$case.value,[StringComparison]::Ordinal)} 'Exact receiver value'}
        Wait-For {(Read-State).($case.mode).writes -eq $before+1} 'Exactly one write'
        Write-Output "Real WPF value mode $($case.mode): expectedError=$([bool]$case.error) passed."
    }
    Write-Output 'Real WPF/native MCP set_value verification passed.'

} finally {
    if ($null -ne $native -and -not $native.HasExited) {
        $native.StandardInput.Close()
        if (-not $native.WaitForExit(3000)) { $native.Kill(); $native.WaitForExit() }
    }
    if ($null -ne $fixture -and -not $fixture.HasExited) { $fixture.Kill(); $fixture.WaitForExit() }
    $fixtureError = Join-Path $directory "fixture.err"
    if (Test-Path -LiteralPath $fixtureError) { Get-Content -LiteralPath $fixtureError | Write-Output }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
