param(
    [string]$SessionId = "default",
    [int]$ScreenIndex = 0,
    [ValidateSet('Claude', 'Codex', 'Pi', 'Cursor')]
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

$popupGap = 8
$popupMargin = 20
$defaultHeight = 100

$pidFile = "$stateDir\.popup-$SessionId.pid"
$dismissFile = "$stateDir\.dismiss-$SessionId"
$logFile = "$stateDir\popup-debug.log"

function Write-PopupLog {
    param([string]$Msg)
    try {
        $ts = Get-Date -Format "HH:mm:ss.fff"
        Add-Content -Path $logFile -Value "[$ts] PID=$PID Screen=$ScreenIndex Session=$SessionId $Msg"
    } catch {}
}

# Stack registry.
#
# Every live popup owns one claim file "<screen>-<pid>.slot" holding
# "<claimTicks>|<height>". Position within a screen is claim order, not a
# count of popups, so a popup that closes frees its place and the popups
# above it slide down into the gap instead of drifting upward forever.
$slotDir = "$stateDir\.slots"
if (-not (Test-Path $slotDir)) {
    $null = New-Item -ItemType Directory -Path $slotDir -Force -ErrorAction SilentlyContinue
}
$claimFile = "$slotDir\$ScreenIndex-$PID.slot"
$script:claimTicks = [DateTime]::UtcNow.Ticks
$script:ownHeight = $defaultHeight
Set-Content -Path $claimFile -Value "$($script:claimTicks)|$defaultHeight" -ErrorAction SilentlyContinue

function Test-PopupAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    return ($proc.ProcessName -like 'powershell*' -or $proc.ProcessName -like 'pwsh*')
}

# Height taken up by the live popups claimed before this one on this screen.
# Claims of dead processes are deleted here, which is what collapses the stack.
function Get-StackOffset {
    $below = 0
    try {
        $claims = New-Object System.Collections.ArrayList
        $files = @(Get-ChildItem "$slotDir\$ScreenIndex-*.slot" -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $parts = $f.BaseName -split '-'
            if ($parts.Count -lt 2) { continue }
            $claimPid = 0
            [int]::TryParse($parts[$parts.Count - 1], [ref]$claimPid) | Out-Null
            if ($claimPid -eq $PID) {
                $null = $claims.Add([pscustomobject]@{ ClaimPid = $PID; Ticks = $script:claimTicks; Height = [double]$script:ownHeight })
                continue
            }
            if (-not (Test-PopupAlive $claimPid)) {
                Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
            $raw = (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
            if (-not $raw) { continue }
            $fields = $raw.Trim() -split '\|'
            if ($fields.Count -lt 2) { continue }
            $null = $claims.Add([pscustomobject]@{ ClaimPid = $claimPid; Ticks = [long]$fields[0]; Height = [double]$fields[1] })
        }
        foreach ($c in @($claims | Sort-Object Ticks, ClaimPid)) {
            if ($c.ClaimPid -eq $PID) { break }
            $below += $c.Height + $popupGap
        }
    } catch {}
    return $below
}

# Top edge this popup should sit at right now.
function Get-TargetTop {
    $top = $wa.Bottom - 10 - $script:ownHeight - (Get-StackOffset)
    if ($top -lt $wa.Top) { $top = $wa.Top }
    return $top
}

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

# Position: bottom-right of screen, stacked above the popups already open
$popupWidth = 350
$window.Left = [Math]::Max($wa.Right - $popupWidth - $popupMargin, $wa.Left)
$window.Top = Get-TargetTop

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

# Animated moves. Top stays under animation control, so the intended
# position is tracked separately instead of read back from the window.
$script:currentTop = $window.Top

function Move-PopupTo {
    param([double]$NewTop, [int]$DurationMs)
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimation
    $animation.From = $script:currentTop
    $animation.To = $NewTop
    $animation.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))
    $animation.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $script:currentTop = $NewTop
    $window.BeginAnimation([System.Windows.Window]::TopProperty, $animation)
}

# Slide-in animation. The real height is only known once the window is laid
# out, so publish it to the claim file before taking a place in the stack.
$window.Add_Loaded({
    if ($window.ActualHeight -gt 0) { $script:ownHeight = $window.ActualHeight }
    Set-Content -Path $claimFile -Value "$($script:claimTicks)|$($script:ownHeight)" -ErrorAction SilentlyContinue
    $script:currentTop = $wa.Bottom
    Move-PopupTo (Get-TargetTop) 300
})

# Reflow: when a popup below this one closes, slide down into the freed space.
$reflowTimer = New-Object System.Windows.Threading.DispatcherTimer
$reflowTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$reflowTimer.Add_Tick({
    $target = Get-TargetTop
    if ([Math]::Abs($target - $script:currentTop) -ge 1) {
        Move-PopupTo $target 200
    }
})
$reflowTimer.Start()

# Give up the slot as soon as this popup goes away.
$window.Add_Closed({
    try { $reflowTimer.Stop() } catch {}
    Remove-Item $claimFile -Force -ErrorAction SilentlyContinue
})

# Append PID to session pid file
Add-Content -Path $pidFile -Value $PID

# Clean dismiss file from previous run if stale
Remove-Item $dismissFile -Force -ErrorAction SilentlyContinue

Write-PopupLog "STARTED"

try {
    $null = $window.ShowDialog()
} catch {
    $_ | Out-File "$stateDir\popup-crash.log"
}
Remove-Item $claimFile -Force -ErrorAction SilentlyContinue
Write-PopupLog "EXITED"
