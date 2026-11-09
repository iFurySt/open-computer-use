param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Re-finding an observed element with production Find-Element over UIA doubles. Runs under pwsh on any OS.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Find-Element", "Same-RuntimeId", "Get-NameDigest")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production element functions missing" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }

function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Element($id, $type, $name, $automationId = "") {
    $element = [pscustomobject]@{ id = $id; Current = [pscustomobject]@{ ControlType = [pscustomobject]@{ ProgrammaticName = $type }; Name = $name; AutomationId = $automationId } }
    $element | Add-Member ScriptMethod GetRuntimeId { @(42, $this.id) }
    return $element
}
function Record($id, $type, $name, $automationId = "") {
    [pscustomobject]@{ index = 4; runtimeId = @(42, $id); controlType = $type; name = $name; nameDigest = Get-NameDigest $name; automationId = $automationId }
}
function Get-MainElement($process) { "window" }
function Get-AllElements($root) { $script:tree }
function Find($record) {
    $failure = $null; $found = $null
    try { $found = Find-Element $null $record } catch { $failure = $_.Exception.Message }
    [pscustomobject]@{ element = $found; error = $failure }
}

$ok1 = Element 1 "ControlType.Button" "OK"
$ok2 = Element 2 "ControlType.Button" "OK"
$cancel = Element 3 "ControlType.Button" "Cancel"
$script:tree = @($ok1, $ok2, $cancel)
Assert ((Find (Record 2 "ControlType.Button" "OK")).element -eq $ok2) "A live RuntimeId was not used"
foreach ($record in @((Record 9 "ControlType.Button" "Cancel"), (Record 9 "ControlType.Button" "OK"), (Record 2 "ControlType.Button" "Cancel"), (Record 2 "ControlType.CheckBox" "OK"), (Record 2 "ControlType.Button" "OK" "different"))) {
    $result = Find $record
    Assert ($null -eq $result.element -and $result.error -match 'get_app_state again') 'Changed/removed identity was not refused'
}
$long = Element 7 "ControlType.Text" ("x" * 600)
$script:tree = @($long)
$record = Record 7 "ControlType.Text" ("x" * 600)
$record.name = ("x" * 500) + "..."
Assert ((Find $record).element -eq $long) 'Truncated display name lost its full identity'
$long.Current.Name = ("x" * 599) + "y"
Assert ($null -eq (Find $record).element) 'Change beyond text limit was missed'
$script:tree = @((Element 10 "ControlType.Pane" ""), (Element 11 "ControlType.Pane" ""))
Assert ($null -eq (Find (Record 9 "ControlType.Pane" "")).element) 'Nameless replacement was guessed'
Write-Output 'Element identity: original RuntimeId plus complete name/type/AutomationId; changed, missing and truncated-tail changes refused.'
