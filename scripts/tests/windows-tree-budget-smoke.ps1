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
    $fixtureSource = Join-Path $PSScriptRoot "fixtures/WindowsTreeBudgetFixture.ps1"
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
    $null = Send-Request "initialize" @{ protocolVersion = "2025-03-26"; capabilities = @{}; clientInfo = @{ name = "windows-tree-budget-smoke"; version = "1" } }
    function Index($result, $name) {
        $matches = [regex]::Matches((Text $result), ('(?m)^\s*(\d+)\s+button ' + [regex]::Escape($name) + '(?:\s|$)'))
        Assert ($matches.Count -eq 1) ("Missing " + $name + ": " + (Text $result))
        $matches[0].Groups[1].Value
    }
    foreach ($budget in @(1200,40)) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $tree=Call-Tool 'get_app_state' @{include_screenshot=$false;max_tree_nodes=$budget}
        Assert (-not $tree.isError) (Text $tree)
        Assert ([regex]::Matches((Text $tree),'(?m)^\s*\d+ ').Count -le $budget) 'Node budget exceeded'
        Write-Output "Budget $budget snapshot returned in $($watch.ElapsedMilliseconds) ms."
        $before=(Read-State).clicks
        $action=Call-Tool 'click' @{element_index=(Index $tree 'Budget open');click_method='accessibility'}
        Assert (-not $action.isError) (Text $action)
        Wait-For {(Read-State).clicks -eq $before+1} 'Indexed footer button'
        Write-Output "Budget $budget retained the footer and its real click succeeded."
    }
    $tree=Call-Tool 'get_app_state' @{include_screenshot=$false;max_tree_nodes=40}
    $action=Call-Tool 'click' @{element_index=(Index $tree 'Budget scroll end');click_method='accessibility'}
    Assert (-not $action.isError) (Text $action)
    Wait-For {(Read-State).scrolled} 'Scroll to last item'
    Start-Sleep -Milliseconds 500
    $tree=Call-Tool 'get_app_state' @{include_screenshot=$false;max_tree_nodes=1200}
    Assert ((Text $tree) -match 'Budget item 1999') 'New visible list item missing after scroll'
    Write-Output 'Real WPF/UIA: 2000-item list, footer actions, strict budgets and newly visible item passed.'
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
