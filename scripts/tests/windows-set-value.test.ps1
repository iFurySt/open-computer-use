param([Parameter(Mandatory=$true)][string]$RuntimePath)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($RuntimePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$function=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-VerifiedSetValue'},$true)
Invoke-Expression $function.Extent.Text
function Assert($value,$message){if(-not $value){throw $message}}
function Pattern($mode) {
    $p=[pscustomobject]@{mode=$mode;writes=0;Current=[pscustomobject]@{IsReadOnly=$false;Value='old'}}
    $p|Add-Member ScriptMethod SetValue {
        param($value)
        $this.writes++
        if($this.mode -eq 'normal'){$this.Current.Value=$value}
        elseif($this.mode -eq 'trim'){$this.Current.Value=$value.Trim()}
    }
    return $p
}
foreach($value in @(''," `t中文🙂`n",'0015','old')){
    $p=Pattern 'normal';Invoke-VerifiedSetValue $p $value
    Assert ($p.writes -eq 1 -and [string]::Equals($p.Current.Value,$value,[StringComparison]::Ordinal)) 'Literal value lost'
}
foreach($mode in @('ignore','trim')){
    $p=Pattern $mode;$failed=$false
    try{Invoke-VerifiedSetValue $p ' padded '}catch{$failed=$_.Exception.Message -match 'could not verify'}
    Assert ($failed -and $p.writes -eq 1) 'Ignored/normalized write passed or retried'
}
$p=Pattern 'normal';$p.Current.IsReadOnly=$true
try{Invoke-VerifiedSetValue $p 'no';throw 'Unexpected success'}catch{Assert ($p.writes -eq 0) 'Read-only control written'}
Write-Output 'Production UIA set_value: exact strings, empty values, no-op, rejection, read-only and single write passed.'
