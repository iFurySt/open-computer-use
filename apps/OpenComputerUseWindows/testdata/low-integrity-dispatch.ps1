param([string]$RuntimePath,[string]$OperationPath)
$ErrorActionPreference='Stop'
# Compile and load production definitions before lowering only this test child.
# No account, parent token, UAC setting or filesystem label is changed.
$source=[IO.File]::ReadAllText($RuntimePath)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$dispatch=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text -match '\$operation\.tool'})
if($dispatch.Count -ne 1){throw 'Production dispatch missing'}
$prefix=$source.Substring($ast.ParamBlock.Extent.EndOffset,$source.IndexOf('$operationJson =')-$ast.ParamBlock.Extent.EndOffset)
Invoke-Expression $prefix
$operation=[IO.File]::ReadAllText($OperationPath)|ConvertFrom-Json
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class LowIntegrity {
 [StructLayout(LayoutKind.Sequential)] struct Label { public IntPtr Sid; public uint Attributes; }
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr handle);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSidToSid(string value,out IntPtr sid);
 [DllImport("advapi32.dll")] static extern int GetLengthSid(IntPtr sid);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetTokenInformation(IntPtr token,int kind,ref Label label,int size);
 public static void Lower() {
  IntPtr token=IntPtr.Zero,sid=IntPtr.Zero;
  try {
   if(!OpenProcessToken(GetCurrentProcess(),0xA8,out token))throw new Win32Exception();
   if(!ConvertStringSidToSid("S-1-16-8192",out sid))throw new Win32Exception();
   Label label=new Label();label.Sid=sid;label.Attributes=0x20;
   if(!SetTokenInformation(token,25,ref label,Marshal.SizeOf(typeof(Label))+GetLengthSid(sid)))throw new Win32Exception();
  } finally {if(sid!=IntPtr.Zero)LocalFree(sid);if(token!=IntPtr.Zero)CloseHandle(token);}
 }
}
'@
$targetBefore=[OCUWin32]::IntegrityLevel([uint32]$operation.expected_pid)
if($targetBefore -lt 0){throw "Target integrity unavailable"}
if($targetBefore -le 0x2000){ @{skip=$true;target=$targetBefore}|ConvertTo-Json -Compress;return }
[LowIntegrity]::Lower()
$own=[OCUWin32]::IntegrityLevel([uint32]$PID)
$target=[OCUWin32]::IntegrityLevel([uint32]$operation.expected_pid)
$response=$null
Invoke-Expression $dispatch[0].Extent.Text
@{own=$own;target=$target;response=$response}|ConvertTo-Json -Depth 50 -Compress
