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
$sequence = 0

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Wait-For($test, $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try { if (& $test) { return } } catch { }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout: $description"
}
function Read-State { Read-WindowsFixtureState $stateFile }
function Send-Request($method, $parameters) {
    $script:requestId += 1
    $message = @{ jsonrpc = "2.0"; id = $script:requestId; method = $method; params = $parameters }
    # .NET Framework's redirected writer may use the system ANSI encoding.
    # Write UTF-8 explicitly so the Unicode value reaches native MCP intact.
    $bytes = [Text.Encoding]::UTF8.GetBytes(($message | ConvertTo-Json -Depth 20 -Compress) + "`n")
    $native.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $native.StandardInput.BaseStream.Flush()
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
# Preserve the array through the pipeline: a single PSCustomObject has no Count
# property in Windows PowerShell 5.1, even though the MCP image is present.
function Images($result) { ,@($result.content | Where-Object type -eq "image") }
function Input-Index($result) {
    $matches = [regex]::Matches((Text $result), '(?m)^\s*(\d+)\s+[^\r\n]+? Observation input(?:\s|$)')
    Assert ($matches.Count -eq 1) (Text $result)
    $matches[0].Groups[1].Value
}
function Change-Window($kind) {
    $script:sequence += 1
    $message = @{ sequence = $script:sequence; kind = $kind } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText(($stateFile + ".command"), $message, [System.Text.Encoding]::UTF8)
    Wait-For { (Read-State).sequence -eq $script:sequence } "fixture window command"
    Start-Sleep -Milliseconds 200
}
try {
    $fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsObservationFixture.ps1"
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
    $null = Send-Request "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-observation-smoke"; version = "1" } }
    $full = Call-Tool "get_app_state" @{}
    Assert (-not $full.isError -and (Images $full).Count -eq 1) (Text $full)
    Write-Output "Normal WPF window returned a validated PNG."
    $oldIndex = Input-Index $full
    $image = Call-Tool "get_app_state" @{ include_ax = $false }
    Assert (-not $image.isError -and (Images $image).Count -eq 1) (Text $image)
    Assert ((Text $image) -match "indexes invalidated" -and (Text $image) -notmatch "Observation input|initial-value") "AX not omitted"
    $stale = Call-Tool "set_value" @{ element_index = $oldIndex; value = "must-not-write" }
    Assert $stale.isError "Stale index accepted"
    $ax = Call-Tool "get_app_state" @{ include_screenshot = $false }
    Assert (-not $ax.isError -and (Images $ax).Count -eq 0) (Text $ax)
    $coordinates = Call-Tool "click" @{ x = 10; y = 10 }
    Assert $coordinates.isError "AX-only coordinate action accepted"
    $value = "live-" + [char]0x4E2D + [char]0x6587
    $write = Call-Tool "set_value" @{ element_index = (Input-Index $ax); value = $value }
    Assert (-not $write.isError) (Text $write)
    Wait-For { (Read-State).text -eq $value } "real UIA value update"
    Write-Output "Selective channels, index refusal/recovery and real Unicode text update passed."
    foreach ($kind in @("tiny", "minimize", "cloak")) {
        Change-Window $kind
        if ($kind -eq "tiny") {
            $state = Read-State
            Assert ($state.width -eq 1 -and $state.height -eq 1) "Window did not become 1x1: $($state.width)x$($state.height)"
        }
        if ($kind -eq "minimize") { Assert (Read-State).minimized "Window did not minimize" }
        if ($kind -eq "cloak") { Assert ((Read-State).cloakHResult -eq 0 -and (Read-State).cloaked -ne 0) "Window did not cloak" }
        $unusable = Call-Tool "get_app_state" @{}
        Assert ((Images $unusable).Count -eq 0) "$kind window returned an image"
        Change-Window "restore"
        $restored = Call-Tool "get_app_state" @{}
        Assert (-not $restored.isError -and (Images $restored).Count -eq 1) (Text $restored)
        Write-Output "$kind window omitted its image; restored window returned a PNG."
    }
    $cli = & $NativePath snapshot --include-screenshot false ([string]$fixture.Id)
    Assert ($LASTEXITCODE -eq 0 -and ($cli -join "`n") -match "include_screenshot=false") "CLI flag not forwarded"
    & node (Join-Path $PSScriptRoot "windows-observation-js-smoke.mjs") $NativePath ([string]$fixture.Id) $stateFile
    Assert ($LASTEXITCODE -eq 0) "Worker JS desktop smoke failed"
    Write-Output "Windows real WPF/native MCP/CLI: channels, stale indexes, AX recovery, coordinate refusal, Unicode text update, 1x1/minimized/cloaked screenshot filtering passed."
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
