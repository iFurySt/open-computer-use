param([Parameter(Mandatory=$true)][string]$StatePath, [switch]$Cover)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text=if($Cover){'OCU Keyboard Cover'}else{'OCU Keyboard Fixture'}
$form.Width=500;$form.Height=300
$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(100,100)
if($Cover){$form.TopMost=$true;[void]$form.ShowDialog();exit}
$one=New-Object Windows.Forms.TextBox;$one.Text='first';$one.AccessibleName='First input';$one.Tag='key1'
$two=New-Object Windows.Forms.TextBox;$two.Text='second';$two.AccessibleName='Second input';$two.Tag='key2'
$two.Multiline=$true;$two.AcceptsReturn=$true
$one.SetBounds(20,20,400,30);$two.SetBounds(20,70,400,70)
$button=New-Object Windows.Forms.Button;$button.Text='No text focus';$button.SetBounds(20,160,200,40)
$form.Controls.AddRange(@($one,$two,$button))
$state=@{sequence=0;one='first';two='second';key1=0;key2=0}
foreach($field in @($one,$two)){$field.Add_KeyDown({param($sender,$event) $state[$sender.Tag]++})}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=30
$encoding=New-Object Text.UTF8Encoding($false)
$timer.Add_Tick({
 if(Test-Path ($StatePath+'.command')){
  try{
   $command=[IO.File]::ReadAllText($StatePath+'.command')|ConvertFrom-Json
   if($command.sequence -gt $state.sequence){
    switch($command.kind){
     'focus-second' {$form.Activate();[void]$two.Focus();$two.Select($two.TextLength,0)}
     'select-second' {$form.Activate();[void]$two.Focus();$two.Select(0,6)}
     'focus-button' {$form.Activate();[void]$button.Focus()}
     'readonly' {$form.Activate();$two.ReadOnly=$true;[void]$two.Focus()}
    }
    $state.sequence=$command.sequence
   }
  }catch{}
 }
 $state.one=$one.Text;$state.two=$two.Text;$state.oneFocused=$one.Focused;$state.twoFocused=$two.Focused;$state.oneHandle=$one.Handle.ToInt64();$state.twoHandle=$two.Handle.ToInt64()
 $temp=$StatePath+'.tmp';[IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Compress),$encoding)
 if(Test-Path $StatePath){[IO.File]::Replace($temp,$StatePath,($StatePath+'.bak'));[IO.File]::Delete($StatePath+'.bak')}else{[IO.File]::Move($temp,$StatePath)}
})
$form.Add_Shown({[void]$two.Focus();$timer.Start()})
[void]$form.ShowDialog();$timer.Stop()
