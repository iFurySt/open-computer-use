param([Parameter(Mandatory = $true)][string]$RuntimePath)
$ErrorActionPreference = "Stop"
# Production click, secondary-action and scroll pattern paths over UIA pattern doubles. Runs under pwsh on any OS;
# which real controls ignore these patterns is a desktop question.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names = @("Wait-PatternState", "Invoke-VerifiedToggle", "Invoke-VerifiedSelect", "Invoke-VerifiedDisclosure", "Invoke-PreferredClick",
    "Invoke-SecondaryAction", "Invoke-Scroll", "Get-CurrentPatternOrNull", "Test-EnvFlagEnabled")
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true)
if ($functions.Count -ne $names.Count) { throw "Production pattern functions missing: $($names | Where-Object { $_ -notin @($functions | ForEach-Object Name) })" }
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
Add-Type -TypeDefinition @"
namespace Windows.Automation {
 public enum ScrollAmount { LargeDecrement, SmallDecrement, NoAmount, LargeIncrement, SmallIncrement }
 public static class InvokePattern { public static string Pattern = "Invoke"; }
 public static class SelectionItemPattern { public static string Pattern = "SelectionItem"; }
 public static class TogglePattern { public static string Pattern = "Toggle"; }
 public static class ExpandCollapsePattern { public static string Pattern = "ExpandCollapse"; }
 public static class ScrollItemPattern { public static string Pattern = "ScrollItem"; }
 public static class ScrollPattern { public static string Pattern = "Scroll"; }
}
"@
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Refuses($call, $pattern) {
    $failure = $null
    try { & $call } catch { $failure = $_.Exception.Message }
    Assert ($null -ne $failure -and $failure -match $pattern) "Expected refusal '$pattern', got '$failure'"
}
# A pattern double whose method applies (or, when ignored, does not apply) the state change it is asked for.
function Pattern([string]$state, [bool]$applies = $true) {
    $pattern = [pscustomobject]@{ state = $state; applies = $applies; calls = 0 }
    $pattern | Add-Member ScriptProperty Current { [pscustomobject]@{ ToggleState = $this.state; IsSelected = ($this.state -eq "Selected"); ExpandCollapseState = $this.state } }
    $pattern | Add-Member ScriptMethod Toggle { $this.calls++; if ($this.applies) { $this.state = if ($this.state -eq "On") { "Off" } else { "On" } } }
    $pattern | Add-Member ScriptMethod Select { $this.calls++; if ($this.applies) { $this.state = "Selected" } }
    $pattern | Add-Member ScriptMethod Expand { $this.calls++; if ($this.applies) { $this.state = "Expanded" } }
    $pattern | Add-Member ScriptMethod Collapse { $this.calls++; if ($this.applies) { $this.state = "Collapsed" } }
    return $pattern
}
function Element([hashtable]$patterns) {
    $element = [pscustomobject]@{ patterns = $patterns }
    $element | Add-Member ScriptMethod GetCurrentPattern { param($name) if (-not $this.patterns.ContainsKey($name)) { throw "unsupported" }; $this.patterns[$name] }
    return $element
}

$p = Pattern "Off"; Invoke-SecondaryAction (Element @{ Toggle = $p }) "toggle"
Assert ($p.state -eq "On" -and $p.calls -eq 1) "A toggle that applied was not accepted once"
$p = Pattern "Off" $false; Refuses { Invoke-SecondaryAction (Element @{ Toggle = $p }) "toggle" } "Toggle could not be verified: the control still reads Off"
Assert ($p.calls -eq 1) "An ignored toggle was sent again"
$p = Pattern "Off" $false; Refuses { Invoke-PreferredClick (Element @{ Toggle = $p }) } "Toggle could not be verified"
$p = Pattern "Unselected" $false; Refuses { Invoke-PreferredClick (Element @{ SelectionItem = $p }) } "Select could not be verified"
$p = Pattern "Unselected"; Assert ((Invoke-PreferredClick (Element @{ SelectionItem = $p })) -and $p.calls -eq 1) "A selection that applied was not accepted"
$p = Pattern "Unselected" $false; Refuses { Invoke-SecondaryAction (Element @{ SelectionItem = $p }) "select" } "Select could not be verified"
$p = Pattern "Collapsed" $false; Refuses { Invoke-SecondaryAction (Element @{ ExpandCollapse = $p }) "expand" } "Expand could not be verified: the item still reads Collapsed"
$p = Pattern "Collapsed"; Invoke-SecondaryAction (Element @{ ExpandCollapse = $p }) "expand"; Assert ($p.state -eq "Expanded") "An expand that applied was not accepted"
$p = Pattern "Expanded" $false; Refuses { Invoke-SecondaryAction (Element @{ ExpandCollapse = $p }) "collapse" } "Collapse could not be verified"
$p = Pattern "Expanded"; Invoke-SecondaryAction (Element @{ ExpandCollapse = $p }) "collapse"; Assert ($p.state -eq "Collapsed") "A collapse that applied was not accepted"
$p = Pattern "Expanded" $false; Invoke-SecondaryAction (Element @{ ExpandCollapse = $p }) "expand"; Assert ($p.calls -eq 1) "Expanding an expanded item failed"
Write-Output "Pattern read-back: toggle, select, expand and collapse applied, ignored (sent once) and already reached passed."

# Scroll: a page that scrolled before the pattern refused is not scrolled again by the wheel fallback.
$script:pages = 0
$scroll = [pscustomobject]@{}
$scroll | Add-Member ScriptMethod Scroll { param($horizontal, $vertical) if ($script:pages -ge $script:limit) { throw "end of content" }; $script:pages++ }
$scrollable = Element @{ Scroll = $scroll }
$script:pages = 0; $script:limit = 1
Assert ((Invoke-Scroll $scrollable "down" 3) -and $script:pages -eq 1) "A scroll that moved one page fell through to the wheel path"
$script:pages = 0; $script:limit = 0
Assert (-not (Invoke-Scroll $scrollable "down" 1)) "A scroll the pattern refused outright did not fall through to the wheel path"
$script:pages = 0; $script:limit = 9
Assert ((Invoke-Scroll $scrollable "up" 2) -and $script:pages -eq 2) "A full scroll failed"
Write-Output "Scroll: partial pages kept, refused scroll falls through, full scroll passed."
