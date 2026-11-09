param([Parameter(Mandatory = $true)][string]$StatePath)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ObservationDwm {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(uint extendedStyle, string windowClass, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")]
    public static extern bool DestroyWindow(IntPtr hwnd);
    public static IntPtr CreateTinyWindow() {
        return CreateWindowEx(0, "STATIC", "OCU Windows Observation Fixture", 0x90000000u,
            80, 80, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int value, int size);
}
"@
$window = New-Object System.Windows.Window
$window.Title = "OCU Windows Observation Fixture"
$window.ShowInTaskbar = $true
$window.Left = 80
$window.Top = 80
$window.Width = 600
$window.Height = 280
$inputBox = New-Object System.Windows.Controls.TextBox
[System.Windows.Automation.AutomationProperties]::SetName($inputBox, "Observation input")
$inputBox.Margin = New-Object System.Windows.Thickness(20)
$inputBox.Height = 30
$inputBox.VerticalAlignment = "Center"
$inputBox.Text = "initial-value"
$panel = New-Object System.Windows.Controls.StackPanel
$passwordBox = New-Object System.Windows.Controls.PasswordBox
$passwordBox.Password = "ocu-password-fixture"
$passwordBox.Height = 30
[System.Windows.Automation.AutomationProperties]::SetName($passwordBox, "Observation password")
[void]$panel.Children.Add($inputBox)
[void]$panel.Children.Add($passwordBox)
$window.Content = $panel
$state = @{ sequence = 0; text = ""; width = 0; height = 0; minimized = $false; cloakHResult = 0; cloaked = 0 }
$stateEncoding = New-Object System.Text.UTF8Encoding($false)
$tinyWindow = @{ handle = [IntPtr]::Zero }
$commandPath = $StatePath + ".command"
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    if (Test-Path -LiteralPath $commandPath) {
        try {
            $command = [System.IO.File]::ReadAllText($commandPath) | ConvertFrom-Json
            if ($command.sequence -gt $state.sequence) {
                switch ($command.kind) {
                    "tiny" {
                        # WPF rounds a one-DIP window to multiple physical
                        # pixels on high-DPI desktops. Use an owned Win32
                        # fixture window for the exact physical 1x1 case.
                        $window.Hide()
                        $tinyWindow.handle = [ObservationDwm]::CreateTinyWindow()
                    }
                    "rename-input" { [System.Windows.Automation.AutomationProperties]::SetName($inputBox, "Renamed input") }
                    "restore-input-name" { [System.Windows.Automation.AutomationProperties]::SetName($inputBox, "Observation input") }
                    "rebuild-input" {
                        $text = $inputBox.Text
                        [void]$panel.Children.Remove($inputBox)
                        $script:inputBox = New-Object System.Windows.Controls.TextBox
                        $inputBox.Text = $text; $inputBox.Height = 30
                        $inputBox.Margin = New-Object System.Windows.Thickness(20)
                        [System.Windows.Automation.AutomationProperties]::SetName($inputBox, "Observation input")
                        $panel.Children.Insert(0, $inputBox)
                    }
                    "selection" { [void]$window.Activate(); [void]$inputBox.Focus(); $inputBox.SelectAll() }
                    "password" { [void]$window.Activate(); [void]$passwordBox.Focus(); $passwordBox.SelectAll() }
                    "minimize" { $window.WindowState = "Minimized" }
                    "cloak" {
                        $value = 1
                        $state.cloakHResult = [ObservationDwm]::DwmSetWindowAttribute($hwnd, 13, [ref]$value, 4)
                    }
                    "restore" {
                        $value = 0
                        [void][ObservationDwm]::DwmSetWindowAttribute($hwnd, 13, [ref]$value, 4)
                        if ($tinyWindow.handle -ne [IntPtr]::Zero) {
                            [void][ObservationDwm]::DestroyWindow($tinyWindow.handle)
                            $tinyWindow.handle = [IntPtr]::Zero
                        }
                        $window.WindowState = "Normal"
                        $window.Width = 600
                        $window.Height = 280
                        $window.Show()
                    }
                }
                $state.sequence = $command.sequence
            }
        } catch { }
    }
    $hwnd = if ($tinyWindow.handle -ne [IntPtr]::Zero) { $tinyWindow.handle }
            else { (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle }
    $cloaked = 0
    [void][ObservationDwm]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloaked, 4)
    $state.cloaked = $cloaked
    $state.text = $inputBox.Text
    $rect = New-Object ObservationDwm+RECT
    [void][ObservationDwm]::GetWindowRect($hwnd, [ref]$rect)
    $state.width = $rect.Right - $rect.Left
    $state.height = $rect.Bottom - $rect.Top
    $state.minimized = $window.WindowState -eq "Minimized"
    $temporary = $StatePath + ".tmp"
    [System.IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json -Compress), $stateEncoding)
    try {
        if (Test-Path -LiteralPath $StatePath) { [System.IO.File]::Replace($temporary, $StatePath, ($StatePath + ".bak")) }
        else { [System.IO.File]::Move($temporary, $StatePath) }
    } catch [System.IO.IOException] { }
})
$timer.Start()
$window.Add_Closed({ $timer.Stop() })
$application = New-Object System.Windows.Application
$application.ShutdownMode = "OnMainWindowClose"
[void]$application.Run($window)
