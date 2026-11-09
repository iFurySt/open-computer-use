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
$cover = $null
try {
    $fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsKeyboardFixture.ps1"
    $fixture = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$stateFile`"") -PassThru -RedirectStandardOutput (Join-Path $directory "fixture.out") -RedirectStandardError (Join-Path $directory "fixture.err")
    Wait-For { Test-Path -LiteralPath $stateFile } "WPF startup"
    Wait-For { (Get-Process -Id $fixture.Id).MainWindowHandle -ne [IntPtr]::Zero } "visible WinForms window"
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
    $observed = Call-Tool "get_app_state" @{ include_screenshot = $false }
    Assert (-not $observed.isError) (Text $observed)
    Change-Window "focus-second"
    $cover = Start-Process powershell.exe -ArgumentList @("-NoProfile", "-STA", "-File", "`"$fixtureSource`"", "-StatePath", "`"$stateFile`"", "-Cover") -PassThru
    Wait-For { (Get-Process -Id $cover.Id).MainWindowHandle -ne [IntPtr]::Zero } 'cover startup'
    Start-Sleep -Milliseconds 300
    $before = Read-State
    $background = Call-Tool "type_text" @{ text = "must-not-guess" }
    Assert ($background.isError -and (Text $background) -match '2 text fields') (Text $background)
    Assert ((Read-State).one -eq $before.one -and (Read-State).two -eq $before.two) 'Background ambiguity modified a field'
    [void]$cover.CloseMainWindow();Wait-For { $cover.HasExited } 'cover exit'
    Change-Window "focus-second"
    Wait-For { (Read-State).twoFocused } 'second input focus'
    $typed = Call-Tool "type_text" @{ text = "-hello" }
    Assert (-not $typed.isError) (Text $typed)
    Wait-For { (Read-State).two -eq 'second-hello' } 'second input actual text'
    Assert ((Read-State).one -eq 'first') 'First input was modified instead'
    Change-Window "select-second"
    $typed = Call-Tool "type_text" @{ text = "chosen" }
    Assert (-not $typed.isError) (Text $typed)
    Wait-For { (Read-State).two -eq 'chosen-hello' } 'selected text replacement'
    $key = Call-Tool "press_key" @{ key = "Return" }
    Assert (-not $key.isError) (Text $key)
    Wait-For { (Read-State).key2 -gt 0 } 'Return reaches focused second child'
    Assert ((Read-State).key1 -eq 0) 'Return reached wrong child'
    $before = Read-State
    $chord = Call-Tool "press_key" @{ key = "ctrl+a" }
    Assert ($chord.isError -and (Text $chord) -match 'cannot carry modifier keys') (Text $chord)
    Assert ((Read-State).two -eq $before.two -and (Read-State).key2 -eq $before.key2) 'Refused chord delivered input'
    foreach ($kind in @('focus-button','readonly')) {
        Change-Window $kind
        $before = Read-State
        $result = Call-Tool "type_text" @{ text = "must-not-type" }
        Assert $result.isError (Text $result)
        Assert ((Read-State).one -eq $before.one -and (Read-State).two -eq $before.two) 'Refused typing changed a field'
    }
    Write-Output 'Real WinForms: focused second-field typing/selection/Return and background ambiguity refusal, refused chord, ambiguous focus and read-only refusal passed.'
} catch {
    if (Test-Path $stateFile) { Write-Output ([IO.File]::ReadAllText($stateFile)) }
    try { Get-Content (Join-Path $directory 'fixture.err') -ErrorAction Stop | Write-Output } catch { }
    throw
} finally {
    if ($native -and -not $native.HasExited) { $native.StandardInput.Close(); if (-not $native.WaitForExit(3000)) { $native.Kill() } }
    foreach ($child in @($cover,$fixture)) { if ($child -and -not $child.HasExited) { [void]$child.CloseMainWindow(); if (-not $child.WaitForExit(3000)) { $child.Kill() } } }
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
