param([string]$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,UIAutomationProvider,UIAutomationTypes,System.Xaml
$refs=@('System.dll',[System.Windows.Markup.IQueryAmbient].Assembly.Location,[System.Windows.Controls.Control].Assembly.Location,[System.Windows.Media.Visual].Assembly.Location,[System.Windows.Threading.DispatcherObject].Assembly.Location,[System.Windows.Automation.Provider.IToggleProvider].Assembly.Location,[System.Windows.Automation.AutomationElementIdentifiers].Assembly.Location)
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
namespace OCUPattern {
 public class Control : System.Windows.Controls.Control {
  public string Kind; public bool Ignore, Value; public int Calls;
  protected override AutomationPeer OnCreateAutomationPeer() { return new Peer(this); }
  public void Apply(bool value) { Calls++; if(!Ignore) Value=value; }
 }
 public class Peer : FrameworkElementAutomationPeer, IToggleProvider, ISelectionItemProvider, IExpandCollapseProvider {
  readonly Control control;
  public Peer(Control owner):base(owner){control=owner;}
  protected override string GetClassNameCore(){return "OCUPatternControl";}
  protected override string GetNameCore(){return control.Name;}
  protected override string GetAutomationIdCore(){return control.Name;}
  protected override AutomationControlType GetAutomationControlTypeCore(){
   return control.Kind=="toggle" ? AutomationControlType.CheckBox : control.Kind=="select" ? AutomationControlType.RadioButton : AutomationControlType.TreeItem;
  }
  public override object GetPattern(PatternInterface pattern){
   if(pattern==PatternInterface.Toggle && control.Kind=="toggle" || pattern==PatternInterface.SelectionItem && control.Kind=="select" || pattern==PatternInterface.ExpandCollapse && control.Kind=="disclosure")return this;
   return base.GetPattern(pattern);
  }
  ToggleState IToggleProvider.ToggleState {get{return control.Value?ToggleState.On:ToggleState.Off;}}
  void IToggleProvider.Toggle(){control.Apply(!control.Value);}
  bool ISelectionItemProvider.IsSelected {get{return control.Value;}}
  IRawElementProviderSimple ISelectionItemProvider.SelectionContainer {get{return null;}}
  void ISelectionItemProvider.Select(){control.Apply(true);}
  void ISelectionItemProvider.AddToSelection(){control.Apply(true);}
  void ISelectionItemProvider.RemoveFromSelection(){control.Apply(false);}
  ExpandCollapseState IExpandCollapseProvider.ExpandCollapseState {get{return control.Value?ExpandCollapseState.Expanded:ExpandCollapseState.Collapsed;}}
  void IExpandCollapseProvider.Expand(){control.Apply(true);}
  void IExpandCollapseProvider.Collapse(){control.Apply(false);}
 }
}
'@
$window=New-Object Windows.Window
$window.Title='OCU pattern readback fixture';$window.Width=550;$window.Height=420
$panel=New-Object Windows.Controls.StackPanel
$controls=@{}
foreach($kind in @('toggle','select','disclosure')) {
 foreach($mode in @('normal','ignore')) {
  $control=New-Object OCUPattern.Control
  $control.Kind=$kind;$control.Ignore=($mode -eq 'ignore');$control.Name=$kind+'_'+$mode
  $control.Width=400;$control.Height=45;$control.Focusable=$true
  [void]$panel.Children.Add($control);$controls[$control.Name]=$control
 }
}
$window.Content=$panel
$encoding=New-Object Text.UTF8Encoding($false)
$statePath=Join-Path $Directory 'state.json'
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
 $state=@{};foreach($name in $controls.Keys){$state[$name]=@{value=$controls[$name].Value;calls=$controls[$name].Calls}}
 $temp=$statePath+'.tmp';[IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 5 -Compress),$encoding)
 if(Test-Path $statePath){[IO.File]::Replace($temp,$statePath,($statePath+'.bak'))}else{[IO.File]::Move($temp,$statePath)}
})
$timer.Start();[void]$window.ShowDialog();$timer.Stop()
