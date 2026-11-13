param([string]$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System.Windows.Forms;
public class IntegrityFixture : Form {
 public int Keys, Characters;
 public IntegrityFixture() { Text="OCU integrity fixture"; Width=450; Height=250; }
 protected override void WndProc(ref Message m) {
  if (m.Msg==0x100) Keys++;
  if (m.Msg==0x102) Characters++;
  base.WndProc(ref m);
 }
}
'@
$form=New-Object IntegrityFixture
$timer=New-Object Windows.Forms.Timer
$timer.Interval=30
$encoding=New-Object Text.UTF8Encoding($false)
$statePath=Join-Path $Directory 'state.json'
$timer.Add_Tick({
 $json=@{keys=$form.Keys;characters=$form.Characters;hwnd=$form.Handle.ToInt64()}|ConvertTo-Json -Compress
 $temp=$statePath+'.tmp';[IO.File]::WriteAllText($temp,$json,$encoding)
 if(Test-Path $statePath){[IO.File]::Replace($temp,$statePath,$statePath+'.bak')}else{[IO.File]::Move($temp,$statePath)}
})
$timer.Start();[Windows.Forms.Application]::Run($form)
