param([string]$Directory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class HostedFixture {
 public delegate IntPtr WindowProc(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct WindowClass {
  public uint Style; public WindowProc Procedure; public int ClassExtra,WindowExtra;
  public IntPtr Instance,Icon,Cursor,Background; public string MenuName,ClassName;
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern ushort RegisterClass(ref WindowClass value);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateWindowEx(uint extended,string className,string title,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr parameter);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr DefWindowProc(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
 public static int Keys;
 static WindowProc procedure=Dispatch;
 static IntPtr Dispatch(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam) {if(message==0x100||message==0x102)Keys++;return DefWindowProc(hwnd,message,wParam,lParam);}
 public static IntPtr Create(string className,string title,IntPtr parent) {
  WindowClass value=new WindowClass();value.ClassName=className;value.Procedure=procedure;value.Instance=GetModuleHandle(null);value.Background=(IntPtr)6;
  // Register once per process; two CoreWindow children share the same class.
  if(RegisterClass(ref value)==0 && Marshal.GetLastWin32Error()!=1410)throw new Win32Exception();
  uint style=parent==IntPtr.Zero ? 0x10CF0000u : 0x50000000u;
  IntPtr hwnd=CreateWindowEx(0,className,title,style,100,100,450,280,parent,IntPtr.Zero,value.Instance,IntPtr.Zero);
  if(hwnd==IntPtr.Zero)throw new Win32Exception();return hwnd;
 }
}
'@
if('__MODE__' -eq 'host') {
 $first=[HostedFixture]::Create('ApplicationFrameWindow','OCU hosted frame',[IntPtr]::Zero)
 $second=[HostedFixture]::Create('OCUOrdinaryFrame','OCU ordinary frame',[IntPtr]::Zero)
}else{
 $first=[HostedFixture]::Create('Windows.UI.Core.CoreWindow','OCU hosted content',[IntPtr]__FIRST__)
 $second=[HostedFixture]::Create('Windows.UI.Core.CoreWindow','OCU ordinary content',[IntPtr]__SECOND__)
}
$statePath=Join-Path $Directory 'state.json'
$encoding=New-Object Text.UTF8Encoding($false)
$timer=New-Object Windows.Forms.Timer
$timer.Interval=30
$timer.Add_Tick({
 $json=@{first=$first.ToInt64();second=$second.ToInt64();keys=[HostedFixture]::Keys}|ConvertTo-Json -Compress
 $temp=$statePath+'.tmp';[IO.File]::WriteAllText($temp,$json,$encoding)
 if(Test-Path $statePath){[IO.File]::Replace($temp,$statePath,$statePath+'.bak')}else{[IO.File]::Move($temp,$statePath)}
})
$timer.Start();[Windows.Forms.Application]::Run()
