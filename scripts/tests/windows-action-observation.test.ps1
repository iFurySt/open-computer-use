param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# The runtime's production dispatch (its top-level try/catch) with stubbed actions and observation. Runs under pwsh
# on any OS.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match '\$operation\.tool' })
if ($dispatch.Count -ne 1) { throw "Production dispatch missing" }

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Start-Sleep { param($Milliseconds) }
function Resolve-App($query) { [pscustomobject]@{ Id = 42; ProcessName = "fixture"; MainWindowHandle = [IntPtr]42 } }
function Find-Element($process, $record) { $null }
function Send-Key($hwnd, $key, $method) { $script:sent++; if ($key -eq "broken") { throw "PostMessage key delivery failed." } }
function Resolve-ObservationOptions($operation) { [pscustomobject]@{ include_ax = $true; include_screenshot = $true } }
function Resolve-TextLimit($value) { 500 }
function Build-Snapshot { if ($script:windowClosed) { throw 'appNotFound("fixture")' }; [pscustomobject]@{ app = [pscustomobject]@{ pid = 42 } } }
function Dispatch($operation) {
    $script:sent = 0
    $response = $null
    Invoke-Expression $dispatch[0].Extent.Text
    return $response
}

$script:windowClosed = $true
$r = Dispatch ([pscustomobject]@{ tool = "press_key"; app = "fixture"; key = "Return" })
Assert ($r.ok -and $script:sent -eq 1 -and $r.observationError -match "appNotFound") "A delivered key whose window then closed was reported as failed: $($r | ConvertTo-Json -Compress)"
Assert ($null -eq $r.snapshot) "A snapshot was returned for a window that could not be read"
$r = Dispatch ([pscustomobject]@{ tool = "get_app_state"; app = "fixture" })
Assert (-not $r.ok -and $r.error -match "appNotFound") "A failed get_app_state was not an error"
$script:windowClosed = $false
$r = Dispatch ([pscustomobject]@{ tool = "press_key"; app = "fixture"; key = "Return" })
Assert ($r.ok -and $r.snapshot.app.pid -eq 42 -and $null -eq $r.observationError) "A delivered key lost its snapshot"
$r = Dispatch ([pscustomobject]@{ tool = "press_key"; app = "fixture"; key = "broken" })
Assert (-not $r.ok -and $r.error -match "delivery failed" -and $null -eq $r.observationError) "A failed action was not an error"
Write-Output "Action dispatch: delivered action with a failed observation, failed observation alone, observed action and failed action passed."
