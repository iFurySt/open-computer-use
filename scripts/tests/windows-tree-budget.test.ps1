param([Parameter(Mandatory=$true)][string]$RuntimePath)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RuntimePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-PrioritizedTree', 'Get-ElementControlTypeName')) {
    $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $function.Extent.Text
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$script:id = 0; $script:reads = 0
function Node($role, $name, $children = @(), $hidden = $false) {
    $script:id++
    $node = [pscustomobject]@{ id=$script:id; name=$name; children=@($children); Current=[pscustomobject]@{ ControlType=[pscustomobject]@{ ProgrammaticName=$role }; IsOffscreen=$hidden } }
    $node | Add-Member ScriptMethod GetRuntimeId { return @($this.id) }
    return $node
}
function Get-TreeChildren($node, $limit) {
    $script:reads += [math]::Min($limit, $node.children.Count)
    [pscustomobject]@{ children=@($node.children | Select-Object -First $limit); truncated=($node.children.Count -gt $limit) }
}
$rows = @(for ($i=0; $i -lt 2000; $i++) { Node 'ControlType.ListItem' "Item $i" })
$list = Node 'ControlType.List' 'Files' $rows
$cancel = Node 'ControlType.Button' 'Cancel'
$footer = Node 'ControlType.Pane' 'Footer' @($cancel)
$root = Node 'ControlType.Window' 'Open' @($list, $footer)
$result = Get-PrioritizedTree $root 20 64
Assert ($result.nodes.Count -le 20 -and $result.truncated) 'Budget or truncation incorrect'
Assert (@($result.nodes | Where-Object { $_.node.name -eq 'Cancel' }).Count -eq 1) 'Later nested Cancel lost'
Assert ($script:reads -le 80) 'Candidate discovery exceeded budget'
$unknown = Node 'ControlType.Button' 'Unknown'
$unknown.Current.PSObject.Properties.Remove('IsOffscreen')
$unknown.Current | Add-Member ScriptProperty IsOffscreen { throw 'Unavailable' }
$hidden = Node 'ControlType.Button' 'Hidden' @() $true
$root = Node 'ControlType.Window' 'Root' @($hidden, $unknown)
$root.children += $root
$result = Get-PrioritizedTree $root 2 64
Assert ($result.nodes.Count -eq 2 -and $result.nodes[1].node.name -eq 'Unknown') 'Unknown visibility discarded or hidden prioritized'
$result = Get-PrioritizedTree $root 20 0
Assert ($result.nodes.Count -eq 1 -and $result.truncated) 'Depth/cycle handling failed'
Write-Output 'Production Windows traversal: nested controls, visibility, original paths, candidate/node/depth bounds and cycles passed.'

foreach ($invalid in @($false, $true)) {
    $root = Node 'ControlType.Window' 'Repeated'
    $entry = if ($invalid) { $null } else { $root }
    $root.children = @($entry) * 10000
    $script:reads = 0
    $result = Get-PrioritizedTree $root 20 64
    Assert ($result.nodes.Count -eq 1 -and $result.truncated) 'Repeated/invalid child truncation failed'
    Assert ($script:reads -le 79) 'Repeated/invalid children bypassed discovery budget'
    $script:reads = 0
    $result = Get-PrioritizedTree $root 20 0
    Assert ($script:reads -eq 0) 'Children read beyond depth limit'
}
Write-Output 'Repeated and invalid child candidates remain bounded.'
