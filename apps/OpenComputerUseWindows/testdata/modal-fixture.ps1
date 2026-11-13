param([string]$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ModalFixtureNative {
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
}
'@
$main=New-Object Windows.Forms.Form
$main.Text='OCU resolution main';$main.Width=450;$main.Height=300
$second=New-Object Windows.Forms.Form
$second.Text='OCU resolution secondary';$second.Width=400;$second.Height=250
$outer=New-Object Windows.Forms.Form
$outer.Text='OCU outer dialog';$outer.Width=400;$outer.Height=250
$inner=New-Object Windows.Forms.Form
$inner.Text='OCU inner dialog';$inner.Width=350;$inner.Height=220
$closeOuter=New-Object Windows.Forms.Button
$closeOuter.Text='Close outer';$closeOuter.Name='close_outer';$closeOuter.Width=150
$closeInner=New-Object Windows.Forms.Button
$closeInner.Text='Close inner';$closeInner.Name='close_inner';$closeInner.Width=150
$outer.Controls.Add($closeOuter);$inner.Controls.Add($closeInner)
$script:innerClicks=0;$script:outerClicks=0;$script:started=$false;$script:nested=$false
$closeInner.Add_Click({$script:innerClicks++;$inner.Close()})
$closeOuter.Add_Click({$script:outerClicks++;$outer.Close()})
$statePath=Join-Path $Directory 'state.json'
$encoding=New-Object Text.UTF8Encoding($false)
$timer=New-Object Windows.Forms.Timer
$timer.Interval=30
$timer.Add_Tick({
 $state=@{main=$main.Handle.ToInt64();second=$second.Handle.ToInt64();outer=$outer.Handle.ToInt64();inner=$inner.Handle.ToInt64();mainEnabled=[ModalFixtureNative]::IsWindowEnabled($main.Handle);outerVisible=$outer.Visible;innerVisible=$inner.Visible;innerClicks=$script:innerClicks;outerClicks=$script:outerClicks}
 $temp=$statePath+'.tmp';[IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Compress),$encoding)
 if(Test-Path $statePath){[IO.File]::Replace($temp,$statePath,$statePath+'.bak')}else{[IO.File]::Move($temp,$statePath)}
 if(-not $script:started -and (Test-Path (Join-Path $Directory 'modal'))) {
  $script:started=$true;[void]$outer.ShowDialog($main)
 } elseif($outer.Visible -and -not $script:nested) {
  $script:nested=$true;[void]$inner.ShowDialog($outer)
 }
})
$main.Show();$second.Show();$timer.Start();[Windows.Forms.Application]::Run()
