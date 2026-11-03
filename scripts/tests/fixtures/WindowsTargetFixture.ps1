param([Parameter(Mandatory=$true)][string]$StatePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
public class OCUClickFixture : Form {
 [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 public int Clicks, LeftUps, RightClicks, PanelClicks;
 public Button Target = new Button();
 public Panel Nested = new Panel();
 public OCUClickFixture() {
  Text="OCU child click regression fixture"; StartPosition=FormStartPosition.Manual;
  Bounds=new Rectangle(100,100,700,500); BackColor=Color.FromArgb(20,80,180);
  Nested.Bounds=new Rectangle(30,40,500,300); Nested.BackColor=BackColor; Controls.Add(Nested);
  Target.FlatStyle=FlatStyle.System; Target.Text="Count fixture clicks"; Target.Bounds=new Rectangle(30,30,220,70);
  Nested.Controls.Add(Target); Target.Click+=(s,e)=>{Clicks++;};
  Target.MouseUp+=(s,e)=>{if(e.Button==MouseButtons.Right)RightClicks++; if(e.Button==MouseButtons.Left)LeftUps++;};
  Nested.MouseUp+=(s,e)=>{PanelClicks++;};
 }
}
'@
[void][OCUClickFixture]::SetProcessDpiAwarenessContext([IntPtr](-4))
[void][OCUClickFixture]::SetThreadDpiAwarenessContext([IntPtr](-4))
$form=New-Object OCUClickFixture
$cover=New-Object System.Windows.Forms.Form
$cover.Text='OCU separate occluder'; $cover.StartPosition='Manual'; $cover.Bounds=$form.Bounds
$cover.TopMost=$true
$cover.BackColor=[System.Drawing.Color]::FromArgb(220,30,120); $cover.ShowInTaskbar=$false
$state=@{sequence=0;pid=$PID}
$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=100
$timer.Add_Tick({
 if(Test-Path ($StatePath+'.command')) {
  try {
   $command=Get-Content -Raw ($StatePath+'.command')|ConvertFrom-Json
   if($command.sequence -gt $state.sequence) {
    switch($command.kind) {
     'cover' {$cover.Bounds=$form.Bounds;$cover.Show();$cover.BringToFront()}
     'uncover' {$cover.Hide()}
     'move' {$form.Left+=60}
     'move-button' {$form.Target.Left+=30}
     'minimize' {$form.WindowState='Minimized'}
     'restore' {$form.WindowState='Normal'}
     'disable' {$form.Target.Enabled=$false}
     'enable' {$form.Target.Enabled=$true}
     'close' {$form.Close()}
    }
    $state.sequence=$command.sequence
   }
  } catch {}
 }
 $point=$form.Target.PointToScreen((New-Object System.Drawing.Point(110,35)))
 $panelPoint=$form.Nested.PointToScreen((New-Object System.Drawing.Point(400,220)))
 $state.clicks=$form.Clicks; $state.leftUps=$form.LeftUps; $state.rightClicks=$form.RightClicks; $state.panelClicks=$form.PanelClicks
 $state.hwnd=$form.Handle.ToInt64(); $state.foreground=[OCUClickFixture]::GetForegroundWindow().ToInt64()
 $state.cursorX=[System.Windows.Forms.Cursor]::Position.X; $state.cursorY=[System.Windows.Forms.Cursor]::Position.Y
 $state.dpi=[OCUClickFixture]::GetDpiForWindow($form.Handle)
 $state.buttonX=$point.X-$form.Left; $state.buttonY=$point.Y-$form.Top
 $state.panelX=$panelPoint.X-$form.Left; $state.panelY=$panelPoint.Y-$form.Top
 [IO.File]::WriteAllText($StatePath,($state|ConvertTo-Json -Compress))
})
$timer.Start()
try {[System.Windows.Forms.Application]::Run($form)} finally {$timer.Stop();$cover.Dispose();$form.Dispose()}
