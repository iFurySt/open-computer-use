param([Parameter(Mandatory=$true)][string]$StatePath)
$ErrorActionPreference="Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class InputFixtureNative {
 [StructLayout(LayoutKind.Sequential)] public struct RECT {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 public static RECT PhysicalFrame(IntPtr hwnd) {
  IntPtr previous=SetThreadDpiAwarenessContext((IntPtr)(-4));
  try {RECT r; GetWindowRect(hwnd,out r); return r;} finally {SetThreadDpiAwarenessContext(previous);}
 }
 public static void PlaceRight(IntPtr hwnd) {
  IntPtr previous=SetThreadDpiAwarenessContext((IntPtr)(-4));
  try {RECT r; GetWindowRect(hwnd,out r); SetWindowPos(hwnd,IntPtr.Zero,GetSystemMetrics(76)+GetSystemMetrics(78)-(r.Right-r.Left)-10,80,0,0,0x15);}
  finally {SetThreadDpiAwarenessContext(previous);}
 }
}
"@
$window=New-Object System.Windows.Window
$window.Title="OCU Input Fixture"
$window.Width=640; $window.Height=460; $window.Left=60; $window.Top=60
$canvas=New-Object System.Windows.Controls.Canvas
$window.Content=$canvas
$button=New-Object System.Windows.Controls.Button
$button.Content="Physical click target"; $button.Width=200; $button.Height=40
[System.Windows.Automation.AutomationProperties]::SetName($button,"Physical click target")
[System.Windows.Controls.Canvas]::SetLeft($button,20); [System.Windows.Controls.Canvas]::SetTop($button,20)
[void]$canvas.Children.Add($button)
$inputBox=New-Object System.Windows.Controls.TextBox
$inputBox.Width=300; $inputBox.Height=32; $inputBox.Text="keyboard-target"
[System.Windows.Automation.AutomationProperties]::SetName($inputBox,"Key target")
[System.Windows.Controls.Canvas]::SetLeft($inputBox,20); [System.Windows.Controls.Canvas]::SetTop($inputBox,75)
[void]$canvas.Children.Add($inputBox)
$dragBox=New-Object System.Windows.Controls.Border
$dragBox.Width=200; $dragBox.Height=40; $dragBox.Background=[System.Windows.Media.Brushes]::LightBlue
[System.Windows.Automation.AutomationProperties]::SetName($dragBox,"Drag target")
[System.Windows.Controls.Canvas]::SetLeft($dragBox,20); [System.Windows.Controls.Canvas]::SetTop($dragBox,120)
[void]$canvas.Children.Add($dragBox)
$scroll=New-Object System.Windows.Controls.ScrollViewer
$scroll.Width=560; $scroll.Height=200; $scroll.HorizontalScrollBarVisibility="Auto"; $scroll.VerticalScrollBarVisibility="Auto"
[System.Windows.Automation.AutomationProperties]::SetName($scroll,"Scroll region")
$content=New-Object System.Windows.Controls.Canvas
$content.Width=1400; $content.Height=1600
$wheelTarget=New-Object System.Windows.Controls.TextBlock
$wheelTarget.Text="Wheel target"; $wheelTarget.FontSize=20
[System.Windows.Automation.AutomationProperties]::SetName($wheelTarget,"Wheel target")
[System.Windows.Controls.Canvas]::SetLeft($wheelTarget,120); [System.Windows.Controls.Canvas]::SetTop($wheelTarget,120)
[void]$content.Children.Add($wheelTarget)
$scroll.Content=$content
[System.Windows.Controls.Canvas]::SetLeft($scroll,20); [System.Windows.Controls.Canvas]::SetTop($scroll,180)
[void]$canvas.Children.Add($scroll)
$state=@{sequence=0;clicks=0;keyCount=0;lastKey="";dragMoves=0;wheelMessages=0;horizontalMessages=0;text="";verticalOffset=0;horizontalOffset=0}
$button.Add_Click({$state.clicks++})
$inputBox.Add_PreviewKeyDown({param($sender,$event) $state.keyCount++; $state.lastKey=$event.Key.ToString()})
$dragBox.Add_MouseMove({param($sender,$event) if($event.LeftButton -eq "Pressed") {$state.dragMoves++}})
$cover=@{window=$null}
$hook=[System.Windows.Interop.HwndSourceHook]{
 param($hwnd,$message,$wParam,$lParam,[ref]$handled)
 if($message -eq 0x20a -or $message -eq 0x20e) {
  $state.rawWheelMessages=[int]$state.rawWheelMessages+1
  $packed=$lParam.ToInt64(); $sx=[int]($packed -band 0xffff); $sy=[int](($packed -shr 16) -band 0xffff)
  if($sx -ge 32768){$sx-=65536}; if($sy -ge 32768){$sy-=65536}
  $point=$scroll.PointFromScreen((New-Object System.Windows.Point($sx,$sy)))
  $state.lastWheelScreenX=$sx; $state.lastWheelScreenY=$sy
  $state.lastWheelLocalX=$point.X; $state.lastWheelLocalY=$point.Y
  if($point.X -ge 0 -and $point.Y -ge 0 -and $point.X -lt $scroll.ActualWidth -and $point.Y -lt $scroll.ActualHeight) {
   $delta=[int](($wParam.ToInt64() -shr 16) -band 0xffff); if($delta -ge 32768){$delta-=65536}
   if($message -eq 0x20a){$state.wheelMessages++;$scroll.ScrollToVerticalOffset($scroll.VerticalOffset-$delta/120*30)}
   else {$state.horizontalMessages++;$scroll.ScrollToHorizontalOffset($scroll.HorizontalOffset+$delta/120*30)}
   $handled.Value=$true
  }
 }
 return [IntPtr]::Zero
}
$window.Add_SourceInitialized({
 $hwnd=(New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
 [System.Windows.Interop.HwndSource]::FromHwnd($hwnd).AddHook($hook)
})
$encoding=New-Object System.Text.UTF8Encoding($false)
$timer=New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
 if(-not $window.IsLoaded){return}
 $hwnd=(New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
 $commandPath=$StatePath+".command"
 if(Test-Path -LiteralPath $commandPath) {
  try {
   $command=[System.IO.File]::ReadAllText($commandPath)|ConvertFrom-Json
   if($command.sequence -gt $state.sequence){
    switch($command.kind){
     "focus" {$window.Activate();$inputBox.Focus()}
     "move" {$window.Left+=40}
     "move-button" {[System.Windows.Controls.Canvas]::SetLeft($button,220)}
     "remove-button" {[void]$canvas.Children.Remove($button)}
     "right" {[InputFixtureNative]::PlaceRight($hwnd)}
     "reset-scroll" {$scroll.ScrollToVerticalOffset(60);$scroll.ScrollToHorizontalOffset(60)}
     "cover" {
      $popup=New-Object System.Windows.Window
      $popup.Title="OCU owned input occluder"; $popup.Owner=$window; $popup.ShowActivated=$false; $popup.Topmost=$true
      $popup.Left=$window.Left; $popup.Top=$window.Top; $popup.Width=$window.Width; $popup.Height=$window.Height
      $popup.Content="Occlusion refusal fixture"; $popup.Show(); $cover.window=$popup
     }
     "uncover" {if($null -ne $cover.window){$cover.window.Close();$cover.window=$null}}
    }
    $state.commandError=""
    $state.sequence=$command.sequence
   }
  } catch { $state.commandError=$_.Exception.Message }
 }
 $rect=[InputFixtureNative]::PhysicalFrame($hwnd)
 $state.x=$rect.Left; $state.y=$rect.Top; $state.width=$rect.Right-$rect.Left; $state.height=$rect.Bottom-$rect.Top
 $state.dpi=[InputFixtureNative]::GetDpiForWindow($hwnd)
 $state.hwnd=$hwnd.ToInt64(); $state.foreground=[InputFixtureNative]::GetForegroundWindow().ToInt64()
 $state.text=$inputBox.Text; $state.verticalOffset=$scroll.VerticalOffset; $state.horizontalOffset=$scroll.HorizontalOffset
 $state.buttonPresent=$canvas.Children.Contains($button)
 foreach($pair in @(@("button",$button),@("drag",$dragBox),@("input",$inputBox))) {
  if(-not $canvas.Children.Contains($pair[1])){continue}
  $point=$pair[1].PointToScreen((New-Object System.Windows.Point(($pair[1].ActualWidth/2),($pair[1].ActualHeight/2))))
  $state[$pair[0]+"X"]=$point.X-$rect.Left; $state[$pair[0]+"Y"]=$point.Y-$rect.Top
 }
 $temporary=$StatePath+".tmp"
 [System.IO.File]::WriteAllText($temporary,($state|ConvertTo-Json -Compress),$encoding)
 try {
  if(Test-Path -LiteralPath $StatePath){[System.IO.File]::Replace($temporary,$StatePath,($StatePath+".bak"))}
  else{[System.IO.File]::Move($temporary,$StatePath)}
 } catch [System.IO.IOException] {}
})
$timer.Start(); $window.Add_Closed({$timer.Stop()})
$application=New-Object System.Windows.Application
$application.ShutdownMode="OnMainWindowClose"
[void]$application.Run($window)
