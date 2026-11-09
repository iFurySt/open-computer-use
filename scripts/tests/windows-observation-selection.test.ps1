param([Parameter(Mandatory=$true)][string]$RuntimePath)
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($RuntimePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Test-ChromiumWindow','Read-SafeSelectedText','Test-PasswordElement','Get-SelectedText','Limit-Text')) {
    $function=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if ($null -eq $function) { throw "Missing production function $name" }
    Invoke-Expression $function.Extent.Text
}
Add-Type @'
public static class OCUWin32 {
    public static string ClassName = "Chrome_WidgetWin_1";
    public static string WindowClass(System.IntPtr hwnd, uint pid) { return ClassName; }
}
'@
if ($env:OS -eq 'Windows_NT') { Add-Type -AssemblyName UIAutomationClient }
else { Add-Type 'namespace Windows.Automation { public class TextPattern { public static object Pattern = new object(); } }' }
function Assert($condition,$message) { if(-not $condition) { throw $message } }
function Get-Process { param($Id,$ErrorAction) [pscustomobject]@{MainWindowHandle=[IntPtr]42} }
foreach ($class in @('Chrome_WidgetWin_1','Chrome_RenderWidgetHostHWND')) {
    [OCUWin32]::ClassName=$class
    Assert (Test-ChromiumWindow 42) 'Chromium class not detected'
    Assert ($null -eq (Get-SelectedText 42)) 'Chromium selection not omitted before UIA focus read'
}
[OCUWin32]::ClassName=$null
Assert ($null -eq (Test-ChromiumWindow 42)) 'Unknown classification lost'
Assert ($null -eq (Get-SelectedText 42)) 'Unknown window probed UIA'
[OCUWin32]::ClassName='HwndWrapper[fixture]'
Assert ((Test-ChromiumWindow 42) -eq $false) 'Native window classified as Chromium'
$script:patternReads=0
function Node($framework,$class,$password) {
    $node=[pscustomobject]@{Current=[pscustomobject]@{FrameworkId=$framework;ClassName=$class;IsPassword=$password}}
    $node | Add-Member ScriptMethod GetCurrentPattern {
        param($pattern)
        $script:patternReads++
        $range=[pscustomobject]@{}
        $range | Add-Member ScriptMethod GetText {param($limit) if($limit -lt 0){return 'ordinary selection'}; return 'ordinary selection'.Substring(0,[Math]::Min(18,$limit))}
        $collection=[pscustomobject]@{Count=1;range=$range}
        $collection | Add-Member ScriptMethod Item {param($index) return $this.range}
        $pattern=[pscustomobject]@{ranges=$collection}
        $pattern | Add-Member ScriptMethod GetSelection {return $this.ranges}
        return $pattern
    }
    return $node
}
foreach ($node in @((Node 'Chrome' '' $false),(Node '' 'Chrome_RenderWidgetHostHWND' $false),(Node '' '' $true))) {
    Assert ($null -eq (Read-SafeSelectedText $node 500)) 'Unsafe provider returned selection'
}
Assert ($script:patternReads -eq 0) 'Unsafe provider TextPattern was requested'
$native=Node 'WPF' '' $false
Assert ((Read-SafeSelectedText $native 500) -eq 'ordinary selection') 'Native selection lost'
Assert ((Read-SafeSelectedText $native 3) -eq 'ord...') 'Selection limit lost'
Assert ((Read-SafeSelectedText $native $null) -eq 'ordinary selection') 'Unlimited selection lost'
Write-Output 'Selection: Chromium root/embedded, unknown window, password and ordinary text limits passed.'
