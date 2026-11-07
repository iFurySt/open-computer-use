param([Parameter(Mandatory=$true)][string]$StatePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,UIAutomationProvider,UIAutomationTypes,System.Xaml
$refs=@('System.dll',[System.Windows.Markup.IQueryAmbient].Assembly.Location,[System.Windows.Controls.TextBox].Assembly.Location,[System.Windows.Media.Visual].Assembly.Location,[System.Windows.Threading.DispatcherObject].Assembly.Location,[System.Windows.Automation.Provider.IValueProvider].Assembly.Location,[System.Windows.Automation.AutomationElementIdentifiers].Assembly.Location)
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Threading;
namespace OCUSetValue {
 public class Box : TextBox {
  public string Mode = "normal";
  public int Writes = 0;
  protected override AutomationPeer OnCreateAutomationPeer() { return new Peer(this); }
 }
 public class Peer : TextBoxAutomationPeer, IValueProvider {
  readonly Box box;
  public Peer(Box owner) : base(owner) { box = owner; }
  public override object GetPattern(PatternInterface pattern) { return pattern == PatternInterface.Value ? this : base.GetPattern(pattern); }
  bool IValueProvider.IsReadOnly { get { return false; } }
  string IValueProvider.Value { get { return box.Text; } }
  void IValueProvider.SetValue(string value) {
   box.Writes++;
   if(box.Mode == "ignore") return;
   if(box.Mode == "trim") { box.Text = value.Trim(); return; }
   if(box.Mode == "numeric") { box.Text = value.TrimStart('0'); return; }
   if(box.Mode == "delay") {
    var timer = new DispatcherTimer(); timer.Interval = TimeSpan.FromMilliseconds(200);
    timer.Tick += (s,e) => { timer.Stop(); box.Text = value; }; timer.Start(); return;
   }
   box.Text = value;
  }
 }
}
'@
$window=New-Object Windows.Window
$window.Title='OCU Set Value Fixture';$window.Width=600;$window.Height=400
$panel=New-Object Windows.Controls.StackPanel
$boxes=@{}
foreach($mode in @('normal','ignore','trim','numeric','delay')){
 $box=New-Object OCUSetValue.Box
 $box.Mode=$mode;$box.Text='old';$box.Height=45;$box.AcceptsReturn=$true
 [Windows.Automation.AutomationProperties]::SetName($box,"Value $mode")
 [void]$panel.Children.Add($box);$boxes[$mode]=$box
}
$window.Content=$panel
$encoding=New-Object Text.UTF8Encoding($false)
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
 $state=@{};foreach($mode in $boxes.Keys){$state[$mode]=@{value=$boxes[$mode].Text;writes=$boxes[$mode].Writes}}
 $temp=$StatePath+'.tmp'
 [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 5 -Compress),$encoding)
 if(Test-Path $StatePath){[IO.File]::Replace($temp,$StatePath,($StatePath+'.bak'))}else{[IO.File]::Move($temp,$StatePath)}
})
$timer.Start();[void]$window.ShowDialog();$timer.Stop()
