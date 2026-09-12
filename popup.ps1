param(
    [string]$SessionId = "default",
    [int]$ScreenIndex = 0,
    [ValidateSet('Claude', 'Codex')]
    [string]$Agent = 'Claude'
)

$stateDir = $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class WinSwitch {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    [DllImport("user32.dll")]
    public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);

    public static void StopFlash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = 0; // FLASHW_STOP
        info.uCount = 0;
        info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }

    public static void BringToFront(IntPtr hwnd) {
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);

        IntPtr fgWnd = GetForegroundWindow();
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(fgWnd, out fgPid);
        uint ourThread = GetCurrentThreadId();
        if (fgThread != ourThread)
            AttachThreadInput(ourThread, fgThread, true);

        SetForegroundWindow(hwnd);

        if (fgThread != ourThread)
            AttachThreadInput(ourThread, fgThread, false);
    }
}
"@

# Read session-specific state
$savedHwnd = [IntPtr]::Zero
$savedTabIndex = 0

$hwndFile = "$stateDir\.hwnd-$SessionId"
$tabIndexFile = "$stateDir\.tabindex-$SessionId"

if (Test-Path $hwndFile) {
    $val = (Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue)
    if ($val) { $savedHwnd = [IntPtr]::new([long]$val) }
}
if (Test-Path $tabIndexFile) {
    $idx = (Get-Content $tabIndexFile -Raw -ErrorAction SilentlyContinue)
    if ($idx) { $savedTabIndex = [int]$idx }
}

$labelFile = "$stateDir\.label-$SessionId"
$label = ""
if (Test-Path $labelFile) {
    $label = (Get-Content $labelFile -Raw -ErrorAction SilentlyContinue)
    if ($label) { $label = $label.Trim() }
}

# Count active popups to determine stack position
$activePopups = 0
Get-ChildItem "$stateDir\.popup-*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $lines = Get-Content $_.FullName -ErrorAction SilentlyContinue
    if ($lines) {
        foreach ($pidLine in $lines) {
            if ($pidLine.Trim()) {
                $proc = Get-Process -Id $pidLine.Trim() -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.HasExited) { $activePopups++ }
            }
        }
    }
}
$screenCount = ([System.Windows.Forms.Screen]::AllScreens).Count
if ($screenCount -gt 1) { $activePopups = [math]::Floor($activePopups / $screenCount) }

$popupHeight = 100
$pidFile = "$stateDir\.popup-$SessionId.pid"
$dismissFile = "$stateDir\.dismiss-$SessionId"

# Get target screen
$screens = [System.Windows.Forms.Screen]::AllScreens
if ($ScreenIndex -ge $screens.Count) { $ScreenIndex = 0 }
$targetScreen = $screens[$ScreenIndex]
$wa = $targetScreen.WorkingArea

# Build the popup window
$window = New-Object System.Windows.Window
$window.WindowStyle = "None"
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.SizeToContent = "Height"
$window.Width = 350
$window.WindowStartupLocation = "Manual"

# Position: bottom-right of screen, clamped within working area
$popupWidth = 350
$margin = 20
$window.Left = [Math]::Max($wa.Right - $popupWidth - $margin, $wa.Left)
$baseTop = [Math]::Max($wa.Bottom - $popupHeight - 10, $wa.Top)
$window.Top = [Math]::Max($baseTop - ($activePopups * $popupHeight), $wa.Top)

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = [System.Windows.CornerRadius]::new(8)
$border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1a1a2e")
$border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f0883e")
$border.BorderThickness = [System.Windows.Thickness]::new(2)
$border.Padding = [System.Windows.Thickness]::new(20, 16, 20, 16)
$border.Cursor = [System.Windows.Input.Cursors]::Hand

$stack = New-Object System.Windows.Controls.StackPanel

$titleBlock = New-Object System.Windows.Controls.TextBlock
$titleBlock.Text = if ($label) { "$Agent - $label" } else { $Agent }
$titleBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f0883e")
$titleBlock.FontSize = 16
$titleBlock.FontWeight = "Bold"
$titleBlock.TextTrimming = "CharacterEllipsis"
$titleBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

$body = New-Object System.Windows.Controls.TextBlock
$body.Text = "Waiting for your input"
$body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#eaeaea")
$body.FontSize = 14
$body.TextWrapping = "Wrap"

# Bottom row: hint left, dismiss right
$bottomRow = New-Object System.Windows.Controls.DockPanel
$bottomRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)

$closeBtn = New-Object System.Windows.Controls.TextBlock
$closeBtn.Text = "Dismiss"
$closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#555555")
$closeBtn.FontSize = 12
$closeBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($closeBtn, "Right")
$closeBtn.Add_MouseEnter({ $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#eaeaea") })
$closeBtn.Add_MouseLeave({ $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#555555") })
$closeBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Write-PopupLog "DISMISS clicked"
    if ($savedHwnd -ne [IntPtr]::Zero -and [WinSwitch]::IsWindow($savedHwnd)) {
        [WinSwitch]::StopFlash($savedHwnd)
    }
    # Signal all siblings to close
    Set-Content $dismissFile "dismiss" -ErrorAction SilentlyContinue
    $window.Close()
})

$hint = New-Object System.Windows.Controls.TextBlock
$hint.Text = "Focus this tab"
$hint.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#888888")
$hint.FontSize = 12

$null = $bottomRow.Children.Add($closeBtn)
$null = $bottomRow.Children.Add($hint)

$null = $stack.Children.Add($titleBlock)
$null = $stack.Children.Add($body)
$null = $stack.Children.Add($bottomRow)
$border.Child = $stack
$window.Content = $border

# Click: signal siblings, bring WT window to front, switch tab, dismiss
$window.Add_MouseLeftButtonDown({
    Write-PopupLog "CLICKED"
    # Signal all siblings to close via dismiss file
    Set-Content $dismissFile "dismiss" -ErrorAction SilentlyContinue
    Write-PopupLog "DISMISS_SIGNAL written"

    if ($savedHwnd -ne [IntPtr]::Zero -and [WinSwitch]::IsWindow($savedHwnd)) {
        [WinSwitch]::StopFlash($savedHwnd)
        [WinSwitch]::BringToFront($savedHwnd)
        $window.Close()
        if ($savedTabIndex -gt 0 -and $savedTabIndex -le 9) {
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.SendKeys]::SendWait("^(%$savedTabIndex)")
        }
    } else {
        Write-PopupLog "NO_HWND or invalid"
        $window.Close()
    }
})

# Auto-close after 30 seconds
$autoCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
$autoCloseTimer.Interval = [TimeSpan]::FromSeconds(30)
$autoCloseTimer.Add_Tick({ Write-PopupLog "TIMEOUT auto-close"; $window.Close() })
$autoCloseTimer.Start()

# Poll for dismiss signal from sibling popups (every 500ms)
$dismissTimer = New-Object System.Windows.Threading.DispatcherTimer
$dismissTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$dismissTimer.Add_Tick({
    if (Test-Path $dismissFile) {
        Write-PopupLog "DISMISS_SIGNAL detected, closing"
        $window.Close()
    }
})
$dismissTimer.Start()

# Slide-in animation
$animTarget = $baseTop - ($activePopups * $popupHeight)
$animFrom = $wa.Bottom
$window.Add_Loaded({
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $animFrom
    $animation.To = $animTarget
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(300))
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $window.BeginAnimation([System.Windows.Window]::TopProperty, $animation)
})

# Append PID to session pid file
Add-Content -Path $pidFile -Value $PID

$logFile = "$stateDir\popup-debug.log"

function Write-PopupLog {
    param([string]$Msg)
    $ts = Get-Date -Format "HH:mm:ss.fff"
    Add-Content -Path $logFile -Value "[$ts] PID=$PID Screen=$ScreenIndex Session=$SessionId $Msg"
}

# Clean dismiss file from previous run if stale
Remove-Item $dismissFile -Force -ErrorAction SilentlyContinue

Write-PopupLog "STARTED"

try {
    $null = $window.ShowDialog()
} catch {
    $_ | Out-File "$stateDir\popup-crash.log"
}
Write-PopupLog "EXITED"
