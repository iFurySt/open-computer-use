param([Parameter(Mandatory=$true)][string]$StatePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$window=New-Object Windows.Window
$window.Title='OCU Windows Tree Budget Fixture'; $window.Width=640; $window.Height=440
$panel=New-Object Windows.Controls.DockPanel
$list=New-Object Windows.Controls.ListBox
$list.Height=300
[Windows.Controls.VirtualizingPanel]::SetIsVirtualizing($list,$false)
[Windows.Controls.ScrollViewer]::SetCanContentScroll($list,$false)
for($i=0;$i -lt 2000;$i++){[void]$list.Items.Add(('Budget item {0:D4}' -f $i))}
[Windows.Controls.DockPanel]::SetDock($list,'Top');[void]$panel.Children.Add($list)
$footer=New-Object Windows.Controls.StackPanel
$footer.Orientation='Horizontal'
$state=@{ clicks=0; scrolled=$false }
$open=New-Object Windows.Controls.Button
$open.Content='Budget open';$open.Width=150;$open.Height=40
$open.Add_Click({$state.clicks++})
$scroll=New-Object Windows.Controls.Button
$scroll.Content='Budget scroll end';$scroll.Width=150;$scroll.Height=40
$scroll.Add_Click({$list.ScrollIntoView($list.Items[1999]);$state.scrolled=$true})
[void]$footer.Children.Add($open);[void]$footer.Children.Add($scroll)
[void]$panel.Children.Add($footer);$window.Content=$panel
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(50)
$encoding=New-Object Text.UTF8Encoding($false)
$timer.Add_Tick({
  $temp=$StatePath+'.tmp'
  [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Compress),$encoding)
  if(Test-Path $StatePath){[IO.File]::Replace($temp,$StatePath,($StatePath+'.bak'));[IO.File]::Delete($StatePath+'.bak')}else{[IO.File]::Move($temp,$StatePath)}
})
$timer.Start();[void]$window.ShowDialog();$timer.Stop()
