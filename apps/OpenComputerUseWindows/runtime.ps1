param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"
$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64
$MinimumScreenshotDimension = 64
$MinimumScreenshotArea = 20000

# Set output encoding to UTF-8 to properly handle non-ASCII characters
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class OCUWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int valueSize);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr ChildWindowFromPointEx(IntPtr hwnd, POINT point, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool IsChild(IntPtr parent, IntPtr child);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    // Hit-test inside the requested window, never against the desktop occluder.
    public static IntPtr ClickTarget(IntPtr root, int x, int y) {
        uint rootPid; GetWindowThreadProcessId(root, out rootPid);
        IntPtr current = root;
        for (int depth = 0; depth < 64; depth++) {
            uint pid; GetWindowThreadProcessId(current, out pid);
            if (rootPid == 0 || pid != rootPid || (current != root && !IsChild(root, current)))
                throw new InvalidOperationException("Click target process/window changed; observe again.");
            if (!IsWindowEnabled(current))
                throw new InvalidOperationException("Click target is disabled.");
            POINT point = new POINT { X = x, Y = y }; RECT client;
            if (!ScreenToClient(current, ref point) || !GetClientRect(current, out client) ||
                point.X < client.Left || point.Y < client.Top || point.X >= client.Right || point.Y >= client.Bottom)
                throw new InvalidOperationException("Posted click is outside the target client area; use accessibility for window chrome.");
            // Skip hidden children, but keep disabled controls so they are refused,
            // rather than delivering their click to the parent underneath them.
            IntPtr child = ChildWindowFromPointEx(current, point, 1);
            if (child == IntPtr.Zero || child == current) return current;
            current = child;
        }
        throw new InvalidOperationException("Click target hierarchy is too deep.");
    }

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")]
    public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx, dy;
        public uint mouseData, flags, time;
        public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort key, scan;
        public uint flags, time;
        public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION data; }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);
    private static void Send(INPUT input) {
        if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput failed (possibly blocked by desktop/integrity restrictions)");
    }
    public static void MouseInput(uint flags, int data) {
        INPUT input = new INPUT();
        input.data.mouse.flags = flags;
        input.data.mouse.mouseData = unchecked((uint)data);
        Send(input);
    }
    public static void KeyInput(int key, bool up) {
        INPUT input = new INPUT(); input.type = 1;
        input.data.keyboard.key = (ushort)key;
        input.data.keyboard.flags = (up ? 2u : 0u) | ((key >= 0x21 && key <= 0x2e) ? 1u : 0u);
        Send(input);
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$WM_SETTEXT = 0x000C
$WM_MOUSEMOVE = 0x0200
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_RBUTTONDOWN = 0x0204
$WM_RBUTTONUP = 0x0205
$WM_MBUTTONDOWN = 0x0207
$WM_MBUTTONUP = 0x0208
$WM_MOUSEWHEEL = 0x020A
$WM_MOUSEHWHEEL = 0x020E
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102
$EM_SETSEL = 0x00B1
$EM_REPLACESEL = 0x00C2

# Screenshot coordinates, UIA bounding rectangles and the windowBounds recorded in
# the operation file are physical pixels, while a DPI-unaware PowerShell process
# reports virtualized metrics from GetSystemMetrics/GetWindowRect. That mismatch
# makes the capturable-window checks reject windows sitting outside the
# virtualized screen and shifts every screenshot coordinate, so pin the process to
# the physical coordinate space before any bounds check runs.
$DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = [IntPtr](-4)
try { [void][OCUWin32]::SetProcessDpiAwarenessContext($DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) } catch { }
# The host may already have selected process awareness. A thread override must
# succeed; silently using virtualized coordinates can target another location.
$previousDpi = [OCUWin32]::SetThreadDpiAwarenessContext($DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
if ($previousDpi -eq [IntPtr]::Zero -or
    [OCUWin32]::GetAwarenessFromDpiAwarenessContext([OCUWin32]::GetThreadDpiAwarenessContext()) -ne 2) {
    throw "Cannot establish per-monitor physical coordinates for the Windows bridge."
}

# Real system input is a deliberate opt-in: it moves the user's pointer and can
# change foreground focus, so the default Windows path stays on UIA patterns and
# Win32 window messages.
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010
$MOUSEEVENTF_MIDDLEDOWN = 0x0020
$MOUSEEVENTF_MIDDLEUP = 0x0040
$MOUSEEVENTF_WHEEL = 0x0800
$MOUSEEVENTF_HWHEEL = 0x1000

function Test-EnvFlagEnabled([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $normalized = $value.Trim().ToLowerInvariant()
    return @("1", "true", "yes", "on") -contains $normalized
}

function New-Frame($x, $y, $width, $height) {
    if ($width -lt 0 -or $height -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = [double]$x
        y = [double]$y
        width = [double]$width
        height = [double]$height
    }
}

function ConvertTo-LParam([int]$x, [int]$y) {
    $packed = (($y -band 0xffff) -shl 16) -bor ($x -band 0xffff)
    [IntPtr]$packed
}

function ConvertTo-WheelWParam([int]$delta) {
    $packed = (($delta -band 0xffff) -shl 16)
    [IntPtr]$packed
}

function Get-WindowRectFrame([IntPtr]$hwnd) {
    $rect = New-Object OCUWin32+RECT
    if ([OCUWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
    }
    return $null
}

function Get-VirtualScreenFrame {
    $x = [OCUWin32]::GetSystemMetrics(76)
    $y = [OCUWin32]::GetSystemMetrics(77)
    $width = [OCUWin32]::GetSystemMetrics(78)
    $height = [OCUWin32]::GetSystemMetrics(79)
    if ($width -le 0 -or $height -le 0) {
        return $null
    }
    return New-Frame $x $y $width $height
}

function Test-FrameIntersectsVirtualScreen($frame) {
    if ($null -eq $frame) {
        return $false
    }
    $virtualScreen = Get-VirtualScreenFrame
    if ($null -eq $virtualScreen) {
        return $false
    }
    return (
        $frame.x -lt ($virtualScreen.x + $virtualScreen.width) -and
        ($frame.x + $frame.width) -gt $virtualScreen.x -and
        $frame.y -lt ($virtualScreen.y + $virtualScreen.height) -and
        ($frame.y + $frame.height) -gt $virtualScreen.y
    )
}

function Test-CapturableFrame($frame) {
    if ($null -eq $frame) {
        return $false
    }
    if ($frame.width -lt $MinimumScreenshotDimension -or $frame.height -lt $MinimumScreenshotDimension) {
        return $false
    }
    if (($frame.width * $frame.height) -lt $MinimumScreenshotArea) {
        return $false
    }
    return Test-FrameIntersectsVirtualScreen $frame
}

function Get-CapturableWindowFrame([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $null
    }
    if (-not [OCUWin32]::IsWindowVisible($hwnd) -or [OCUWin32]::IsIconic($hwnd)) {
        return $null
    }
    try {
        [int]$cloaked = 0
        $result = [OCUWin32]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloaked, 4)
        if ($result -ne 0 -or $cloaked -ne 0) {
            return $null
        }
    } catch {
        # An unknown DWM visibility state is not a trustworthy screenshot
        # source. Keep the accessibility tree, but fail closed for the image.
        return $null
    }
    $frame = Get-WindowRectFrame $hwnd
    if (-not (Test-CapturableFrame $frame)) {
        return $null
    }
    return $frame
}

function Get-ElementFrame($element, $windowBounds) {
    try {
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $null
        }
        if ($null -ne $windowBounds) {
            return New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height
        }
        return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
    } catch {
        return $null
    }
}

function Get-ScreenPoint($localFrame, $windowBounds) {
    Assert-UsableWindowBounds $windowBounds
    if ($null -eq $localFrame) {
        throw "No usable element frame is available for screenshot-coordinate input."
    }
    [pscustomobject]@{
        x = [int][math]::Round($windowBounds.x + $localFrame.x + ($localFrame.width / 2))
        y = [int][math]::Round($windowBounds.y + $localFrame.y + ($localFrame.height / 2))
    }
}

function Assert-UsableWindowBounds($windowBounds) {
    if (-not (Test-CapturableFrame $windowBounds)) {
        throw "No usable screenshot coordinates are available. Restore a visible, non-minimized, on-screen window and run get_app_state again."
    }
}

function Test-GlobalPointerFallbackEnabled {
    return (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS")
}

function Assert-GlobalInputTarget([IntPtr]$hwnd, [bool]$AllowActivation = $true) {
    if (-not (Test-GlobalPointerFallbackEnabled)) { throw "Global input requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1" }
    if ($null -eq (Get-CapturableWindowFrame $hwnd)) { throw "Global input requires a visible, usable target window. Run get_app_state again." }
    if ([OCUWin32]::GetForegroundWindow() -ne $hwnd -and $AllowActivation) {
        [void][OCUWin32]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 100
    }
    if ([OCUWin32]::GetForegroundWindow() -ne $hwnd) {
        throw "Global input refused: target window is not foreground. Activate the target and observe it again."
    }
}

function Assert-CurrentWindowBounds([IntPtr]$hwnd, $expected) {
    Assert-UsableWindowBounds $expected
    $current = Get-CapturableWindowFrame $hwnd
    foreach ($field in @("x", "y", "width", "height")) {
        if ($null -eq $current -or [double]$current.$field -ne [double]$expected.$field) {
            throw "Window geometry changed; run get_app_state before coordinate input."
        }
    }
}

function Assert-GlobalPointerTarget([IntPtr]$hwnd, [int]$x, [int]$y, $bounds, [bool]$AllowActivation = $true) {
    Assert-CurrentWindowBounds $hwnd $bounds
    if ($x -lt $bounds.x -or $y -lt $bounds.y -or $x -ge ($bounds.x + $bounds.width) -or $y -ge ($bounds.y + $bounds.height)) {
        throw "Global input point is outside the observed target window."
    }
    Assert-GlobalInputTarget $hwnd $AllowActivation
    $point = New-Object OCUWin32+POINT
    $point.X = $x; $point.Y = $y
    $hit = [OCUWin32]::WindowFromPoint($point)
    if ($hit -eq [IntPtr]::Zero -or [OCUWin32]::GetAncestor($hit, 2) -ne $hwnd) {
        throw "Global input refused: point is covered by another window."
    }
}

function Resolve-GlobalElementPoint($element, $record, $bounds) {
    if ($null -eq $element -or @($record.runtimeId).Count -eq 0 -or
        -not (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId))) {
        throw "Observed element is no longer available; run get_app_state before physical input."
    }
    $current = Get-ElementFrame $element $bounds
    foreach ($field in @("x", "y", "width", "height")) {
        if ($null -eq $current -or $null -eq $record.frame -or
            [math]::Abs([double]$current.$field - [double]$record.frame.$field) -gt 1) {
            throw "Element geometry changed; run get_app_state before physical input."
        }
    }
    return Get-ScreenPoint $current $bounds
}

function Send-GlobalMouseMove([IntPtr]$hwnd, [int]$x, [int]$y, $bounds, [bool]$AllowActivation = $true) {
    Assert-GlobalPointerTarget $hwnd $x $y $bounds $AllowActivation
    if (-not [OCUWin32]::SetCursorPos($x, $y)) { throw "SetCursorPos failed" }
    Assert-GlobalPointerTarget $hwnd $x $y $bounds $false
}

function Send-GlobalMouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count, $bounds) {
    if ($button -notin @("left", "right", "middle")) { throw "Unsupported global mouse button: $button" }
    if ($count -lt 1 -or $count -gt 3) { throw "Global click_count must be between 1 and 3." }
    $down = $MOUSEEVENTF_LEFTDOWN; $up = $MOUSEEVENTF_LEFTUP; $virtualKey = 1
    if ($button -eq "right") { $down = $MOUSEEVENTF_RIGHTDOWN; $up = $MOUSEEVENTF_RIGHTUP; $virtualKey = 2 }
    elseif ($button -eq "middle") { $down = $MOUSEEVENTF_MIDDLEDOWN; $up = $MOUSEEVENTF_MIDDLEUP; $virtualKey = 4 }
    if ([OCUWin32]::GetAsyncKeyState($virtualKey) -lt 0) { throw "Mouse button is already held; global input refused." }
    Send-GlobalMouseMove $hwnd $screenX $screenY $bounds
    for ($i = 0; $i -lt [math]::Max(1, $count); $i++) {
        Assert-GlobalPointerTarget $hwnd $screenX $screenY $bounds $false
        try {
            [OCUWin32]::MouseInput($down, 0)
            Start-Sleep -Milliseconds 30
        } finally { [OCUWin32]::MouseInput($up, 0) }
        Start-Sleep -Milliseconds 60
    }
}

function Send-MouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count, $bounds) {
    Assert-CurrentWindowBounds $hwnd $bounds
    if ($button -notin @("", "left", "right", "middle")) { throw "Unsupported posted mouse button '$button'." }
    if ($count -lt 1 -or $count -gt 3) { throw "Click count must be between 1 and 3." }
    $target = [OCUWin32]::ClickTarget($hwnd, $screenX, $screenY)
    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    if (-not [OCUWin32]::ScreenToClient($target, [ref]$point)) { throw "ScreenToClient failed for click target." }
    $lParam = ConvertTo-LParam $point.X $point.Y

    $down = $WM_LBUTTONDOWN
    $up = $WM_LBUTTONUP
    $downFlag = 0x0001
    if ($button -eq "right") {
        $down = $WM_RBUTTONDOWN
        $up = $WM_RBUTTONUP
        $downFlag = 0x0002
    } elseif ($button -eq "middle") {
        $down = $WM_MBUTTONDOWN
        $up = $WM_MBUTTONUP
        $downFlag = 0x0010
    }

    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        Assert-CurrentWindowBounds $hwnd $bounds
        if ([OCUWin32]::ClickTarget($hwnd, $screenX, $screenY) -ne $target) { throw "Click target changed; observe again." }
        # A child can move inside an unchanged top-level window, retaining its HWND.
        $currentPoint = New-Object OCUWin32+POINT
        $currentPoint.X = $screenX
        $currentPoint.Y = $screenY
        if (-not [OCUWin32]::ScreenToClient($target, [ref]$currentPoint) -or
            $currentPoint.X -ne $point.X -or $currentPoint.Y -ne $point.Y) {
            throw "Click target geometry changed; observe again."
        }
        if (-not [OCUWin32]::PostMessage($target, $WM_MOUSEMOVE, [IntPtr]::Zero, $lParam)) { throw "PostMessage mouse move delivery failed." }
        try {
            if (-not [OCUWin32]::PostMessage($target, $down, [IntPtr]$downFlag, $lParam)) { throw "PostMessage mouse down delivery failed." }
            Start-Sleep -Milliseconds 35
        } finally {
            if (-not [OCUWin32]::PostMessage($target, $up, [IntPtr]::Zero, $lParam)) { throw "PostMessage mouse up delivery failed." }
        }
        Start-Sleep -Milliseconds 50
    }
}

function Send-Drag([IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY, $bounds) {
    if (Test-GlobalPointerFallbackEnabled) {
        Assert-GlobalPointerTarget $hwnd $toX $toY $bounds
        if ([OCUWin32]::GetAsyncKeyState(1) -lt 0) { throw "Mouse button is already held; global input refused." }
        Send-GlobalMouseMove $hwnd $fromX $fromY $bounds
        try {
            [OCUWin32]::MouseInput($MOUSEEVENTF_LEFTDOWN, 0)
            for ($i = 1; $i -le 12; $i++) {
                $x = [int][math]::Round($fromX + (($toX - $fromX) * $i / 12))
                $y = [int][math]::Round($fromY + (($toY - $fromY) * $i / 12))
                Send-GlobalMouseMove $hwnd $x $y $bounds $false
                Start-Sleep -Milliseconds 20
            }
        } finally { [OCUWin32]::MouseInput($MOUSEEVENTF_LEFTUP, 0) }
        return
    }
    $start = New-Object OCUWin32+POINT
    $start.X = $fromX
    $start.Y = $fromY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$start)
    $end = New-Object OCUWin32+POINT
    $end.X = $toX
    $end.Y = $toY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$end)

    $steps = 12
    $startParam = ConvertTo-LParam $start.X $start.Y
    [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $startParam)
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONDOWN, [IntPtr]1, $startParam)
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($start.X + (($end.X - $start.X) * $i / $steps))
        $y = [int][math]::Round($start.Y + (($end.Y - $start.Y) * $i / $steps))
        [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]1, (ConvertTo-LParam $x $y))
        Start-Sleep -Milliseconds 20
    }
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONUP, [IntPtr]::Zero, (ConvertTo-LParam $end.X $end.Y))
}

function Send-Scroll([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages, $bounds) {
    if (Test-GlobalPointerFallbackEnabled) {
        Send-GlobalMouseMove $hwnd $screenX $screenY $bounds
        $delta = [int][math]::Round(120 * $pages)
        if ($direction -eq "down" -or $direction -eq "left") { $delta = -1 * $delta }
        $message = $MOUSEEVENTF_WHEEL
        if ($direction -eq "left" -or $direction -eq "right") { $message = $MOUSEEVENTF_HWHEEL }
        Assert-GlobalPointerTarget $hwnd $screenX $screenY $bounds $false
        [OCUWin32]::MouseInput($message, $delta)
        Start-Sleep -Milliseconds 120
        return
    }
    # WM_MOUSEWHEEL / WM_MOUSEHWHEEL carry screen coordinates, unlike clicks.
    $lParam = ConvertTo-LParam $screenX $screenY
    $delta = [int][math]::Round(120 * $pages)
    $message = $WM_MOUSEWHEEL
    if ($direction -eq "down" -or $direction -eq "left") {
        $delta = -1 * $delta
    }
    if ($direction -eq "left" -or $direction -eq "right") {
        $message = $WM_MOUSEHWHEEL
    }
    if (-not [OCUWin32]::PostMessage($hwnd, $message, (ConvertTo-WheelWParam $delta), $lParam)) {
        throw "PostMessage wheel delivery failed."
    }
}

function Send-Text([IntPtr]$hwnd, [string]$text) {
    foreach ($char in $text.ToCharArray()) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_CHAR, [IntPtr][int][char]$char, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 8
    }
}

function Send-TextToEditHandle([IntPtr]$hwnd, [string]$text, $element) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $false
    }

    try {
        [void][OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr](-1), [IntPtr](-1))
        [void][OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL, [IntPtr]1, $text)
        return $true
    } catch {
    }

    try {
        $current = ""
        if ($null -ne $element) {
            $current = Get-ElementValue $element
        }
        [void][OCUWin32]::SendMessage($hwnd, $WM_SETTEXT, [IntPtr]::Zero, ($current + $text))
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualKey([string]$key) {
    $normalized = $key.ToLowerInvariant()
    $map = @{
        "return" = 0x0D; "enter" = 0x0D; "tab" = 0x09; "escape" = 0x1B; "esc" = 0x1B
        "backspace" = 0x08; "back_space" = 0x08; "delete" = 0x2E; "space" = 0x20
        "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28
        "home" = 0x24; "end" = 0x23; "page_up" = 0x21; "prior" = 0x21; "page_down" = 0x22; "next" = 0x22
    }
    if ($map.ContainsKey($normalized)) {
        return $map[$normalized]
    }
    if ($normalized -match "^f([1-9]|1[0-2])$") {
        return 0x70 + [int]$Matches[1] - 1
    }
    if ($normalized -match "^kp_([0-9])$") {
        return 0x60 + [int]$Matches[1]
    }
    if ($normalized.Length -eq 1) {
        $code = [int][char]$normalized.ToUpperInvariant()[0]
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) {
            return $code
        }
    }
    throw "Unsupported key: $key"
}

function Send-Key([IntPtr]$hwnd, [string]$key, [string]$method = "auto") {
    if ($method -eq "global") {
        $parts = $key -split "\+"
        # Resolve and validate the entire chord before any key goes down.
        $vk = Get-VirtualKey $parts[-1]
        $modifiers = New-Object System.Collections.Generic.List[int]
        foreach ($part in $parts[0..([math]::Max(0, $parts.Length - 2))]) {
            if ($parts.Length -eq 1) { break }
            $modifier = switch ($part.ToLowerInvariant()) {
                "ctrl" { 0x11 }; "control" { 0x11 }; "shift" { 0x10 }; "alt" { 0x12 }
                "super" { 0x5B }; "win" { 0x5B }; "cmd" { 0x5B }
                default { throw "Unsupported key modifier: $part" }
            }
            if (-not $modifiers.Contains($modifier)) { $modifiers.Add($modifier) }
        }
        $keys = @($modifiers.ToArray()) + @($vk)
        foreach ($item in $keys) {
            if ([OCUWin32]::GetAsyncKeyState($item) -lt 0) { throw "Requested key is already held; global input refused." }
        }
        Assert-GlobalInputTarget $hwnd
        $pressed = New-Object System.Collections.Generic.List[int]
        try {
            foreach ($item in $keys) {
                Assert-GlobalInputTarget $hwnd $false
                $pressed.Add($item)
                [OCUWin32]::KeyInput($item, $false)
            }
            Start-Sleep -Milliseconds 30
        } finally {
            $cleanupErrors = @()
            for ($i = $pressed.Count - 1; $i -ge 0; $i--) {
                try { [OCUWin32]::KeyInput($pressed[$i], $true) } catch { $cleanupErrors += $_ }
            }
            if ($cleanupErrors.Count -gt 0) { throw "Global key release failed: $($cleanupErrors -join '; ')" }
        }
        return
    }
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = @()
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers += 0x11 }
            "control" { $modifiers += 0x11 }
            "shift" { $modifiers += 0x10 }
            "alt" { $modifiers += 0x12 }
            "super" { $modifiers += 0x5B }
            "win" { $modifiers += 0x5B }
            "cmd" { $modifiers += 0x5B }
        }
    }
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$modifier, [IntPtr]::Zero)
    }
    $vk = Get-VirtualKey $main
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$vk, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 25
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$vk, [IntPtr]::Zero)
    [array]::Reverse($modifiers)
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$modifier, [IntPtr]::Zero)
    }
}

function Resolve-App([string]$query) {
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $processes = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        $match = $processes | Where-Object { $_.Id -eq $pidValue } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    $match = $processes | Where-Object {
        $_.ProcessName -ieq $processQuery -or
        "$($_.ProcessName).exe" -ieq $normalized -or
        $_.MainWindowTitle -ieq $normalized -or
        $_.MainWindowTitle -ilike "*$normalized*"
    } | Select-Object -First 1
    if ($null -ne $match) {
        return $match
    }

    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
        try {
            $started = Start-Process -FilePath $normalized -PassThru
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $candidate = Get-Process -Id $started.Id -ErrorAction SilentlyContinue
                if ($null -ne $candidate -and $candidate.MainWindowHandle -ne 0) {
                    return $candidate
                }
            }
        } catch {
        }
    }

    throw "appNotFound(`"$query`")"
}

function Get-MainElement($process) {
    if ($process.MainWindowHandle -ne 0) {
        return [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    }
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
    $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($children.Count -gt 0) {
        return $children.Item(0)
    }
    throw "No top-level UI Automation window is available for $($process.ProcessName). Run the Windows runtime in the signed-in desktop session."
}

function Get-WindowBounds($process, $element) {
    $hwnd = [IntPtr]$process.MainWindowHandle
    return Get-CapturableWindowFrame $hwnd
}

function Get-PatternNames($element) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $element.GetSupportedPatterns()) {
        $programmatic = $pattern.ProgrammaticName
        if ($programmatic -like "InvokePatternIdentifiers.Pattern") { $names.Add("Invoke") }
        elseif ($programmatic -like "TogglePatternIdentifiers.Pattern") { $names.Add("Toggle") }
        elseif ($programmatic -like "SelectionItemPatternIdentifiers.Pattern") { $names.Add("Select") }
        elseif ($programmatic -like "ExpandCollapsePatternIdentifiers.Pattern") {
            try {
                $state = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
                if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $names.Add("Expand") }
                elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $names.Add("Collapse") }
            } catch {
                $names.Add("Expand")
                $names.Add("Collapse")
            }
        }
        elseif ($programmatic -like "ScrollItemPatternIdentifiers.Pattern") { $names.Add("ScrollIntoView") }
        elseif ($programmatic -like "ScrollPatternIdentifiers.Pattern") { $names.Add("Scroll") }
        elseif ($programmatic -like "ValuePatternIdentifiers.Pattern") { $names.Add("SetValue") }
    }
    if ($names.Count -gt 0) {
        return @($names | Select-Object -Unique)
    }
    return @()
}

function Get-ElementString($element, [string]$propertyName) {
    try {
        $value = $element.Current.$propertyName
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ElementInt64($element, [string]$propertyName) {
    try {
        return [int64]$element.Current.$propertyName
    } catch {
        return 0
    }
}

function Get-ElementControlTypeName($element) {
    try {
        $controlType = $element.Current.ControlType
        if ($null -eq $controlType) {
            return ""
        }
        return [string]$controlType.ProgrammaticName
    } catch {
        return ""
    }
}

function Resolve-TextLimit($Value) {
    if ($null -eq $Value) {
        return $script:DefaultTextLimit
    }
    if ($Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq "max") {
        return $null
    }
    if ($Value -is [bool]) {
        return $script:DefaultTextLimit
    }
    try {
        $integer = [int]$Value
        if ($integer -gt 0) {
            return $integer
        }
    } catch {
    }
    return $script:DefaultTextLimit
}

function Limit-Text([string]$Text, $TextLimit = $script:DefaultTextLimit) {
    if ($null -eq $Text) {
        return ""
    }
    if ($null -eq $TextLimit) {
        return $Text
    }
    $effectiveTextLimit = [int]$TextLimit
    if ($Text.Length -gt $effectiveTextLimit) {
        return $Text.Substring(0, $effectiveTextLimit) + "..."
    }
    return $Text
}

function Get-ElementValue($element, $TextLimit = $script:DefaultTextLimit) {
    try {
        $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $value = $valuePattern.Current.Value
        if ($null -eq $value) {
            return ""
        }
        $text = [string]$value
        return Limit-Text $text $TextLimit
    } catch {
        return ""
    }
}

function Get-ElementRecord($element, [int]$index, $windowBounds, $TextLimit = $script:DefaultTextLimit) {
    $frame = Get-ElementFrame $element $windowBounds
    $runtimeId = @()
    try { $runtimeId = @($element.GetRuntimeId()) } catch {}
    [pscustomobject]@{
        index = $index
        runtimeId = $runtimeId
        automationId = Get-ElementString $element "AutomationId"
        name = Limit-Text (Get-ElementString $element "Name") $TextLimit
        controlType = Get-ElementControlTypeName $element
        localizedControlType = Get-ElementString $element "LocalizedControlType"
        className = Get-ElementString $element "ClassName"
        value = Get-ElementValue $element $TextLimit
        nativeWindowHandle = Get-ElementInt64 $element "NativeWindowHandle"
        frame = $frame
        actions = @(Get-PatternNames $element)
    }
}

function Get-ElementTitle($record) {
    if (-not [string]::IsNullOrWhiteSpace($record.name)) {
        return $record.name
    }
    if (-not [string]::IsNullOrWhiteSpace($record.automationId)) {
        return "ID: $($record.automationId)"
    }
    return ""
}

# This cache lives only for one snapshot. Action targets are still resolved afresh.
function New-TreeCacheRequest {
    $cache = New-Object Windows.Automation.CacheRequest
    $cache.TreeScope = [Windows.Automation.TreeScope]::Element
    $cache.TreeFilter = [Windows.Automation.Condition]::TrueCondition
    foreach ($name in @('ControlType', 'IsOffscreen', 'BoundingRectangle', 'AutomationId', 'Name', 'LocalizedControlType', 'ClassName', 'NativeWindowHandle',
        'IsInvokePatternAvailable', 'IsTogglePatternAvailable', 'IsSelectionItemPatternAvailable', 'IsExpandCollapsePatternAvailable',
        'IsScrollItemPatternAvailable', 'IsScrollPatternAvailable', 'IsValuePatternAvailable')) {
        $cache.Add([Windows.Automation.AutomationElement]::($name + 'Property'))
    }
    $cache.Add([Windows.Automation.ValuePattern]::ValueProperty)
    $cache.Add([Windows.Automation.ExpandCollapsePattern]::ExpandCollapseStateProperty)
    return $cache
}

function Get-TreeRecord($element, [int]$index, $windowBounds, $TextLimit) {
    try {
        $info = $element.Cached
        $rect = $info.BoundingRectangle
        $frame = $null
        if (-not $rect.IsEmpty -and $rect.Width -gt 0 -and $rect.Height -gt 0) {
            $frame = if ($null -eq $windowBounds) { New-Frame $rect.X $rect.Y $rect.Width $rect.Height }
                     else { New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height }
        }
        $actions = New-Object System.Collections.Generic.List[string]
        foreach ($pair in @(@('Invoke', 'Invoke'), @('Toggle', 'Toggle'), @('SelectionItem', 'Select'),
            @('ScrollItem', 'ScrollIntoView'), @('Scroll', 'Scroll'), @('Value', 'SetValue'))) {
            if ($element.GetCachedPropertyValue([Windows.Automation.AutomationElement]::('Is' + $pair[0] + 'PatternAvailableProperty'))) {
                $actions.Add($pair[1])
            }
        }
        if ($element.GetCachedPropertyValue([Windows.Automation.AutomationElement]::IsExpandCollapsePatternAvailableProperty)) {
            $state = $element.GetCachedPropertyValue([Windows.Automation.ExpandCollapsePattern]::ExpandCollapseStateProperty)
            if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $actions.Add('Expand') }
            elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $actions.Add('Collapse') }
        }
        $value = ''
        if ($element.GetCachedPropertyValue([Windows.Automation.AutomationElement]::IsValuePatternAvailableProperty)) {
            $value = Limit-Text ([string]$element.GetCachedPropertyValue([Windows.Automation.ValuePattern]::ValueProperty)) $TextLimit
        }
        return [pscustomobject]@{
            index = $index
            runtimeId = @($element.GetCachedPropertyValue([Windows.Automation.AutomationElement]::RuntimeIdProperty))
            automationId = $info.AutomationId
            name = Limit-Text $info.Name $TextLimit
            controlType = $info.ControlType.ProgrammaticName
            localizedControlType = $info.LocalizedControlType
            className = $info.ClassName
            value = $value
            nativeWindowHandle = [int64]$info.NativeWindowHandle
            frame = $frame
            actions = $actions.ToArray()
        }
    } catch {
        return Get-ElementRecord $element $index $windowBounds $TextLimit
    }
}

function Get-TreeChildren($node, [int]$limit) {
    if ($limit -le 0) {
        return [pscustomobject]@{ children = @(); truncated = ($null -ne [Windows.Automation.TreeWalker]::RawViewWalker.GetFirstChild($node)) }
    }
    $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt [math]::Min($children.Count, $limit); $i++) { $result.Add($children.Item($i)) }
    [pscustomobject]@{ children = $result.ToArray(); truncated = ($children.Count -gt $limit) }
}

function Get-PrioritizedTree($root, [int]$MaxNodes, [int]$MaxDepth) {
    $queues = @(); $offsets = @(0, 0, 0, 0, 0)
    for ($i = 0; $i -lt 5; $i++) { $queues += ,(New-Object System.Collections.Generic.List[object]) }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $selected = New-Object System.Collections.Generic.List[object]
    $state = @{ scanned = 0; truncated = $false; limit = [math]::Max(64, [math]::Min($MaxNodes, 2500) * 4) }
    function Enqueue($node, [int]$depth, [string]$path, [bool]$inCollection) {
        if ($depth -gt $MaxDepth -or $state.scanned -ge $state.limit) { $state.truncated = $true; return }
        $state.scanned++
        if ($null -eq $node) { return }
        try { $runtime = (@($node.GetCachedPropertyValue([Windows.Automation.AutomationElement]::RuntimeIdProperty)) -join '.') }
        catch { try { $runtime = (@($node.GetRuntimeId()) -join '.') } catch { $runtime = $path } }
        if ([string]::IsNullOrWhiteSpace($runtime)) { $runtime = $path }
        if (-not $seen.Add($runtime)) { return }
        try { $role = $node.Cached.ControlType.ProgrammaticName } catch { $role = Get-ElementControlTypeName $node }
        if ([string]::IsNullOrWhiteSpace($role)) { $role = Get-ElementControlTypeName $node }
        $collection = $inCollection -or $role -in @('ControlType.List', 'ControlType.DataGrid', 'ControlType.Tree', 'ControlType.Table')
        $hidden = $false
        try {
            $info = $node.Cached
            if ($null -eq $info) { $info = $node.Current }
            $hidden = [bool]$info.IsOffscreen
        } catch { try { $hidden = [bool]$node.Current.IsOffscreen } catch { } }
        $control = $role -in @('ControlType.Button', 'ControlType.CheckBox', 'ControlType.RadioButton', 'ControlType.Edit', 'ControlType.ComboBox', 'ControlType.Slider', 'ControlType.Spinner', 'ControlType.Hyperlink')
        $rank = if ($hidden) { 4 } elseif ($collection) { if ($control) { 2 } else { 3 } } elseif ($control) { 0 } else { 1 }
        $queues[$rank].Add([pscustomobject]@{ node = $node; depth = $depth; path = $path; collection = $collection })
    }
    Enqueue $root 0 '' $false
    while ($selected.Count -lt $MaxNodes) {
        $rank = -1
        for ($i = 0; $i -lt 5; $i++) { if ($offsets[$i] -lt $queues[$i].Count) { $rank = $i; break } }
        if ($rank -lt 0) { break }
        $work = $queues[$rank][$offsets[$rank]]; $offsets[$rank]++
        $selected.Add($work)
        try {
            $remaining = if ($work.depth -ge $MaxDepth) { 0 } else { [math]::Max(0, $state.limit - $state.scanned) }
            $result = Get-TreeChildren $work.node $remaining
            if ($result.truncated) { $state.truncated = $true }
            for ($i = 0; $i -lt $result.children.Count; $i++) {
                Enqueue $result.children[$i] ($work.depth + 1) ($work.path + '/' + $i.ToString('D10')) $work.collection
            }
        } catch { $state.truncated = $true }
    }
    for ($i = 0; $i -lt 5; $i++) { if ($offsets[$i] -lt $queues[$i].Count) { $state.truncated = $true } }
    [pscustomobject]@{ nodes = @($selected | Sort-Object path); truncated = $state.truncated }
}

function Render-Tree($element, $windowBounds, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth) {
    $records = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $effectiveMaxTreeNodes = if ($MaxTreeNodes -gt 0) { $MaxTreeNodes } else { $script:AccessibilityTreeMaxNodeCount }
    $effectiveMaxTreeDepth = if ($MaxTreeDepth -gt 0) { $MaxTreeDepth } else { $script:AccessibilityTreeMaxDepth }
    $cache = New-TreeCacheRequest
    $scope = $cache.Activate()
    try {
        try { $element = $element.GetUpdatedCache($cache) } catch { }
        $plan = Get-PrioritizedTree $element $effectiveMaxTreeNodes $effectiveMaxTreeDepth
    } finally { $scope.Dispose() }
    foreach ($work in $plan.nodes) {
        $depth = $work.depth
        $index = $records.Count
        $record = Get-TreeRecord $work.node $index $windowBounds $TextLimit
        $records.Add($record)
        $role = $record.localizedControlType
        if ([string]::IsNullOrWhiteSpace($role)) {
            $role = $record.controlType
        }
        $title = Get-ElementTitle $record
        $actionsSegment = ""
        if ($record.actions.Count -gt 0) {
            $actionsSegment = " Secondary Actions: " + ($record.actions -join ", ")
        }
        $valueSegment = ""
        if (-not [string]::IsNullOrWhiteSpace($record.value) -and $record.value -ne $title) {
            $safeValue = (($record.value -replace "`r", "\\r") -replace "`n", "\\n")
            $valueSegment = " Value: $safeValue"
        }
        $frameSegment = ""
        if ($null -ne $record.frame) {
            $frameSegment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}" -f [int][math]::Round($record.frame.x), [int][math]::Round($record.frame.y), [int][math]::Round($record.frame.width), [int][math]::Round($record.frame.height)
        }
        $lines.Add(("`t" * ($depth + 1)) + "$index $role $title$valueSegment$actionsSegment$frameSegment")

    }
    if ($plan.truncated) {
        $lines.Add('[Accessibility tree truncated: prioritized visible controls; some nodes were omitted.]')
    }

    [pscustomobject]@{
        records = $records.ToArray()
        lines = $lines.ToArray()
    }
}

function Capture-WindowPngBase64($bounds, [IntPtr]$hwnd) {
    if (-not (Test-CapturableFrame $bounds)) {
        return $null
    }
    $bitmap = $null
    $graphics = $null
    $stream = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap ([int][math]::Round($bounds.width)), ([int][math]::Round($bounds.height))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        Assert-CurrentWindowBounds $hwnd $bounds
        # PW_RENDERFULLCONTENT captures the requested HWND even when occluded.
        # Never substitute desktop pixels on failure: they may belong to another app.
        # The bridge process has a 30-second timeout for unresponsive renderers.
        $hdc = $graphics.GetHdc()
        try {
            if (-not [OCUWin32]::PrintWindow($hwnd, $hdc, 2)) { return $null }
        } finally { $graphics.ReleaseHdc($hdc) }
        Assert-CurrentWindowBounds $hwnd $bounds
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $stream.ToArray()
        return [Convert]::ToBase64String($bytes)
    } catch {
        return $null
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-FocusedSummary($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $role = $focused.Current.LocalizedControlType
            $name = Limit-Text $focused.Current.Name $TextLimit
            if ([string]::IsNullOrWhiteSpace($name)) {
                return $role
            }
            return "$role $name"
        }
    } catch {
    }
    return $null
}

function Get-SelectedText($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            return $null
        }
        $textPattern = $focused.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $selection = $textPattern.GetSelection()
        if ($selection.Count -gt 0) {
            $maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }
            return Limit-Text ($selection.Item(0).GetText($maxLength)) $TextLimit
        }
    } catch {
    }
    return $null
}

function Resolve-ObservationOptions($operation) {
    $values = @{ include_ax = $true; include_screenshot = $true }
    foreach ($key in @("include_ax", "include_screenshot")) {
        $property = $operation.PSObject.Properties[$key]
        if ($null -ne $property) {
            if ($property.Value -isnot [bool]) { throw "$key must be a boolean" }
            $values[$key] = $property.Value
        }
    }
    if (-not $values.include_ax -and -not $values.include_screenshot) {
        throw "At least one of include_ax or include_screenshot must be true"
    }
    return [pscustomobject]$values
}

function Build-Snapshot([string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, [bool]$IncludeAX = $true, [bool]$IncludeScreenshot = $true) {
    if (-not $IncludeAX -and -not $IncludeScreenshot) {
        throw "At least one of include_ax or include_screenshot must be true"
    }
    $process = Resolve-App $query
    $element = Get-MainElement $process
    $bounds = Get-WindowBounds $process $element
    $rendered = @{ lines = @(); records = @() }
    $focus = $null
    $selection = $null
    $image = $null
    if ($IncludeAX) {
        $rendered = Render-Tree $element $bounds $TextLimit $MaxTreeNodes $MaxTreeDepth
        $focus = Get-FocusedSummary $process.Id $TextLimit
        $selection = Get-SelectedText $process.Id $TextLimit
    }
    if ($IncludeScreenshot) { $image = Capture-WindowPngBase64 $bounds ([IntPtr]$process.MainWindowHandle) }
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        windowHandle = [long]$process.MainWindowHandle
        windowTitle = Limit-Text $process.MainWindowTitle $TextLimit
        windowBounds = $bounds
        screenshotPngBase64 = $image
        treeLines = @($rendered.lines)
        focusedSummary = $focus
        selectedText = $selection
        elements = @($rendered.records)
    }
}

function List-Apps {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object ProcessName, Id)) {
        if ($null -eq (Get-CapturableWindowFrame ([IntPtr]$process.MainWindowHandle))) {
            continue
        }
        $title = $process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "untitled"
        }
        $lines.Add(("{0} -- {1} [running, pid={2}, window={3}]" -f $process.ProcessName, $process.ProcessName, $process.Id, $title))
    }
    return ($lines -join "`n")
}

function Same-RuntimeId($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
}

function Get-AllElements($root) {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($root)
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count; $i++) {
            $items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

function Find-Element($process, $record) {
    if ($null -eq $record) {
        return $null
    }
    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        try {
            if (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId)) {
                return $element
            }
        } catch {
        }
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            $sameAutomationId = -not [string]::IsNullOrWhiteSpace($record.automationId) -and $element.Current.AutomationId -eq $record.automationId
            $sameName = -not [string]::IsNullOrWhiteSpace($record.name) -and $element.Current.Name -eq $record.name
            $sameType = $element.Current.ControlType.ProgrammaticName -eq $record.controlType
            if (($sameAutomationId -or $sameName) -and $sameType) {
                return $element
            }
        } catch {
        }
    }
    return $null
}

function Invoke-VerifiedSetValue($pattern, [string]$value) {
    if ($pattern.Current.IsReadOnly) { throw "Cannot set a value for an element that is not settable" }
    $pattern.SetValue($value)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $matched = $false
        try { $matched = [string]::Equals($pattern.Current.Value, $value, [StringComparison]::Ordinal) } catch { }
        if ($matched) { return }
        if ($clock.Elapsed.TotalSeconds -ge 0.6) {
            throw "set_value could not verify the requested value. Read the current value before retrying; the write may have changed the control."
        }
        Start-Sleep -Milliseconds 50
    }
}

function Get-CurrentPatternOrNull($element, $pattern) {
    try {
        return $element.GetCurrentPattern($pattern)
    } catch {
        return $null
    }
}

function Invoke-PreferredClick($element) {
    $invoke = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $invoke) {
        $invoke.Invoke()
        return $true
    }
    $selection = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
    if ($null -ne $selection) {
        $selection.Select()
        return $true
    }
    $toggle = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
    if ($null -ne $toggle) {
        $toggle.Toggle()
        return $true
    }
    return $false
}

function Invoke-SecondaryAction($element, [string]$action) {
    switch ($action.ToLowerInvariant()) {
        "invoke" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Invoke(); return }
        }
        "toggle" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Toggle(); return }
        }
        "select" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Select(); return }
        }
        "expand" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Expand(); return }
        }
        "collapse" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Collapse(); return }
        }
        "scrollintoview" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.ScrollIntoView(); return }
        }
        "setfocus" {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
                throw "SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it."
            }
            $element.SetFocus()
            return
        }
    }
    throw "$action is not a valid secondary action for $($operation.element.index)"
}

function Invoke-Scroll($element, [string]$direction, [double]$pages) {
    $scroll = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollPattern]::Pattern)
    if ($null -eq $scroll) {
        return $false
    }
    $horizontal = [Windows.Automation.ScrollAmount]::NoAmount
    $vertical = [Windows.Automation.ScrollAmount]::NoAmount
    if ($direction -eq "up") { $vertical = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "down") { $vertical = [Windows.Automation.ScrollAmount]::LargeIncrement }
    elseif ($direction -eq "left") { $horizontal = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "right") { $horizontal = [Windows.Automation.ScrollAmount]::LargeIncrement }
    $repeat = [math]::Max(1, [int][math]::Ceiling($pages))
    for ($i = 0; $i -lt $repeat; $i++) {
        try {
            $scroll.Scroll($horizontal, $vertical)
        } catch {
            # ScrollPattern can exist while the element still refuses to scroll in
            # its current state, for example a list with two rows. Fall through to
            # the coordinate path instead of failing the whole tool call.
            return $false
        }
        Start-Sleep -Milliseconds 40
    }
    return $true
}

function Find-TextEntryElement($process) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $process.Id) {
            $focusedValue = Get-CurrentPatternOrNull $focused ([Windows.Automation.ValuePattern]::Pattern)
            if ($null -ne $focusedValue -and -not $focusedValue.Current.IsReadOnly) {
                return $focused
            }
        }
    } catch {
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            continue
        }
        $controlType = Get-ElementControlTypeName $element
        if ($controlType -like "*Edit*" -or $controlType -like "*Document*") {
            return $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return $element
        }
    }

    return $null
}

function Get-NativeWindowHandle($element) {
    $handle = Get-ElementInt64 $element "NativeWindowHandle"
    if ($handle -le 0) {
        return [IntPtr]::Zero
    }
    return [IntPtr]$handle
}

function Test-TextWindowHandleCandidate($process, $element) {
    if ($null -eq $element) {
        return $false
    }
    $handle = Get-NativeWindowHandle $element
    if ($handle -eq [IntPtr]::Zero -or $handle -eq [IntPtr]$process.MainWindowHandle) {
        return $false
    }
    $controlType = Get-ElementControlTypeName $element
    $className = Get-ElementString $element "ClassName"
    return (
        $controlType -like "*Edit*" -or
        $controlType -like "*Document*" -or
        $className -like "*Edit*" -or
        $className -like "*Rich*" -or
        $className -like "*Text*"
    )
}

function Find-TextEntryWindowHandle($process, $preferredElement) {
    if (Test-TextWindowHandleCandidate $process $preferredElement) {
        return Get-NativeWindowHandle $preferredElement
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        if (-not (Test-TextWindowHandleCandidate $process $element)) {
            continue
        }
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return Get-NativeWindowHandle $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        if (Test-TextWindowHandleCandidate $process $element) {
            return Get-NativeWindowHandle $element
        }
    }

    return [IntPtr]::Zero
}

function Invoke-TypeText($process, [string]$text) {
    $element = Find-TextEntryElement $process
    $targetHwnd = Find-TextEntryWindowHandle $process $element
    if ($targetHwnd -ne [IntPtr]::Zero -and (Send-TextToEditHandle $targetHwnd $text $element)) {
        return $true
    }

    if ($null -ne $element) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
                throw "UIA ValuePattern text fallback is disabled by default because it may bring the target app to the foreground; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 to enable it."
            }
            $current = ""
            try { $current = [string]$valuePattern.Current.Value } catch {}
            $valuePattern.SetValue($current + $text)
            return $true
        }
    }
    return $false
}

# Read the operation file as UTF-8 explicitly. Windows PowerShell 5.1's
# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
$operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
$operation = $operationJson | ConvertFrom-Json

try {
    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "get_app_state") {
        $observation = Resolve-ObservationOptions $operation
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) $observation.include_ax $observation.include_screenshot) }
    } else {
        $process = Resolve-App $operation.app
        $hwnd = [IntPtr]$process.MainWindowHandle
        if (($operation.expected_pid -gt 0 -and $process.Id -ne $operation.expected_pid) -or
            ($operation.windowHandle -gt 0 -and [long]$hwnd -ne $operation.windowHandle)) {
            throw "Target process/window changed; run get_app_state before acting."
        }
        $windowBounds = $operation.windowBounds
        $element = Find-Element $process $operation.element

        switch ($operation.tool) {
            "click" {
                $clickMethod = [string]$operation.click_method
                if ([string]::IsNullOrWhiteSpace($clickMethod)) { $clickMethod = "auto" }

                if ($clickMethod -eq "accessibility") {
                    if ($null -eq $element) { throw "click_method 'accessibility' requires element_index" }
                    if ($operation.mouse_button -eq "right" -or $operation.mouse_button -eq "middle") {
                        throw "click_method 'accessibility' does not support mouse_button '$($operation.mouse_button)'"
                    }
                    if (-not (Invoke-PreferredClick $element)) {
                        throw "click_method 'accessibility' could not click the requested element"
                    }
                } elseif ($clickMethod -eq "app_post") {
                    Assert-UsableWindowBounds $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                    Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                } elseif ($clickMethod -eq "global") {
                    if (-not (Test-GlobalPointerFallbackEnabled)) {
                        throw "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
                    }
                    Assert-UsableWindowBounds $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                    Send-GlobalMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                } elseif ($clickMethod -eq "sky_click") {
                    throw "click_method 'sky_click' is not supported on Windows"
                } elseif ($clickMethod -eq "auto") {
                    $handled = $false
                    if ($null -ne $element -and $operation.mouse_button -ne "right" -and $operation.mouse_button -ne "middle") {
                        $handled = Invoke-PreferredClick $element
                    }
                    if (-not $handled) {
                        Assert-UsableWindowBounds $windowBounds
                        if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                            $point = Get-ScreenPoint $operation.element.frame $windowBounds
                        } else {
                            $point = [pscustomobject]@{
                                x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                                y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                            }
                        }
                        if (Test-GlobalPointerFallbackEnabled) {
                            if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                            Send-GlobalMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                        } else {
                            if ($null -ne $operation.element) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                            Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count) $windowBounds
                        }
                    }
                } else {
                    throw "Invalid click_method '$clickMethod'"
                }
            }
            "perform_secondary_action" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                Invoke-SecondaryAction $element $operation.action
            }
            "scroll" {
                $handled = $false
                if ($null -ne $element) {
                    $handled = Invoke-Scroll $element $operation.direction ([double]$operation.pages)
                }
                if (-not $handled) {
                    Assert-UsableWindowBounds $windowBounds
                    $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    if (Test-GlobalPointerFallbackEnabled) { $point = Resolve-GlobalElementPoint $element $operation.element $windowBounds }
                    Send-Scroll $hwnd $point.x $point.y $operation.direction ([double]$operation.pages) $windowBounds
                }
            }
            "drag" {
                Assert-UsableWindowBounds $windowBounds
                Send-Drag $hwnd ([int][math]::Round($windowBounds.x + [double]$operation.from_x)) ([int][math]::Round($windowBounds.y + [double]$operation.from_y)) ([int][math]::Round($windowBounds.x + [double]$operation.to_x)) ([int][math]::Round($windowBounds.y + [double]$operation.to_y)) $windowBounds
            }
            "type_text" {
                if (-not (Invoke-TypeText $process $operation.text)) {
                    Send-Text $hwnd $operation.text
                }
            }
            "press_key" {
                Send-Key $hwnd $operation.key $operation.key_method
            }
            "set_value" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
                if ($null -eq $valuePattern) {
                    throw "Cannot set a value for an element that is not settable"
                }
                Invoke-VerifiedSetValue $valuePattern ([string]$operation.value)
            }
            default {
                throw "unsupportedTool(`"$($operation.tool)`")"
            }
        }

        Start-Sleep -Milliseconds 120
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app) }
    }
} catch {
    $message = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        $message = "$message at $($_.ScriptStackTrace)"
    }
    $response = [pscustomobject]@{ ok = $false; error = $message }
}

$response | ConvertTo-Json -Depth 50 -Compress
