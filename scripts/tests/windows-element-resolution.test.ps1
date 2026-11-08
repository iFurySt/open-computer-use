param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Re-finding an observed element with production Find-Element over UIA doubles. Runs under pwsh on any OS.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Find-Element", "Same-RuntimeId")
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
    [pscustomobject]@{ index = 4; runtimeId = @(42, $id); controlType = $type; name = $name; automationId = $automationId }
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
Assert ((Find (Record 9 "ControlType.Button" "Cancel")).element -eq $cancel) "A unique control was not re-found after its RuntimeId changed"
$twins = Find (Record 9 "ControlType.Button" "OK")
Assert ($null -eq $twins.element -and $twins.error -match "matches 2 controls") "Two controls named OK resolved to one of them: $($twins.element.id)"
Assert ($null -eq (Find (Record 9 "ControlType.CheckBox" "Cancel")).element) "A control of another type was taken"

# List rows often share one AutomationId; the name tells them apart.
$rowA = Element 5 "ControlType.ListItem" "a.txt" "row"
$rowB = Element 6 "ControlType.ListItem" "b.txt" "row"
$script:tree = @($rowA, $rowB)
$row = Find (Record 9 "ControlType.ListItem" "b.txt" "row")
Assert ($row.element -eq $rowB) "The row named b.txt resolved to $($row.element.Current.Name)"
Assert ($null -eq (Find (Record 9 "ControlType.ListItem" "c.txt" "row")).element) "A row whose name is gone resolved to another row"

# A snapshot cuts names at text_limit and marks the cut with "...".
$long = Element 7 "ControlType.Text" ("x" * 600)
$script:tree = @($long, (Element 8 "ControlType.Text" "Delete..."))
Assert ((Find (Record 9 "ControlType.Text" (("x" * 500) + "..."))).element -eq $long) "A name cut at text_limit was not matched"
Assert ($null -eq (Find (Record 9 "ControlType.Text" "Remove all...")).element) "A cut name matched a control that does not start with it"
Assert ((Find (Record 9 "ControlType.Text" "Delete...")).element.id -eq 8) "A name that ends in ... was not matched exactly"

# Without a name or AutomationId there is nothing to re-find by.
$script:tree = @((Element 10 "ControlType.Pane" ""), (Element 11 "ControlType.Pane" ""))
Assert ($null -eq (Find (Record 9 "ControlType.Pane" "")).element) "A nameless control was guessed"
Write-Output "Element re-resolution: live RuntimeId, unique identity, twins refused, shared AutomationId, cut names and nameless controls passed."
