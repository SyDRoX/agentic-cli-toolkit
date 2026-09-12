#Requires -Version 5.1
<#
.SYNOPSIS
    Opens ONE Windows Terminal window with 4 Claude Code tabs, one per repo,
    maximized on the target monitor.
.DESCRIPTION
    Adapted from SyDroX/dev-layout (MIT). Divergences from upstream:
      - One window instead of two.
      - Each tab gets its OWN working directory (upstream: 4 tabs share one
        workspace root).
      - Maximizes on the target monitor instead of Win+Arrow half-screen snap,
        so the fragile keybd_event simulation is gone.
      - No --model flag; Claude Code picks its own default.
      - No cd-blocking hook (each tab is already scoped to a single repo).
.PARAMETER DryRun
    Print the wt.exe command that would be run, then exit. Launches nothing.
.NOTES
    Session resume is the point of this script. See launch-claude.ps1.
#>

param(
    [switch]$DryRun
)

# ============================================================================
# ENVIRONMENT
# ============================================================================

# Resolve pwsh.exe full path (wt.exe is a UWP app and won't inherit PATH changes)
$registryPath = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path
$PwshExe = ($registryPath.Split(';') |
    Where-Object { $_ -and (Test-Path (Join-Path $_ "pwsh.exe") -ErrorAction SilentlyContinue) } |
    Select-Object -First 1 |
    ForEach-Object { Join-Path $_ "pwsh.exe" })
if (-not $PwshExe) {
    Write-Error "pwsh.exe not found. Install PowerShell 7: winget install Microsoft.PowerShell"
    return
}

# ============================================================================
# CONFIGURATION
# ============================================================================

$Config = @{
    # One tab per repo, in order. Tab N maps to session slot w1-tN, so the
    # order here is load-bearing: reordering these reassigns saved sessions.
    Tabs = @(
        @{ Title = "ormi-unity";         WorkingDir = "C:\Repos\ormi-unity" }
        @{ Title = "PotatoSandwich";     WorkingDir = "C:\Repos\PotatoSandwich" }
        @{ Title = "WaaaghGamez";        WorkingDir = "C:\Repos\WaaaghGamez" }
        @{ Title = "DefendYourCastle3D"; WorkingDir = "C:\Repos\DefendYourCastle3D" }
    )
    # Monitor index after sorting by X. 0 = leftmost (DISPLAY2), 1 = primary.
    TargetMonitor = 0
    WindowNum     = 1
    SettleDelayMs = 150
}

$StateDir = Join-Path $env:USERPROFILE ".claude\dev-layout"

# ============================================================================
# WINDOWS API
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms

$WinApiSource = @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public class WinApi
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    public const int SW_RESTORE  = 9;
    public const int SW_MAXIMIZE = 3;

    public static bool ForceForeground(IntPtr hWnd)
    {
        IntPtr foreground = GetForegroundWindow();
        uint dummy1, dummy2;
        uint foregroundThread = GetWindowThreadProcessId(foreground, out dummy1);
        uint targetThread = GetWindowThreadProcessId(hWnd, out dummy2);
        uint currentThread = GetCurrentThreadId();

        if (foregroundThread != currentThread)
            AttachThreadInput(currentThread, foregroundThread, true);
        if (targetThread != currentThread)
            AttachThreadInput(currentThread, targetThread, true);

        SetForegroundWindow(hWnd);
        ShowWindow(hWnd, SW_RESTORE);

        if (foregroundThread != currentThread)
            AttachThreadInput(currentThread, foregroundThread, false);
        if (targetThread != currentThread)
            AttachThreadInput(currentThread, targetThread, false);

        return true;
    }

    public static string GetWindowTitle(IntPtr hWnd)
    {
        int length = GetWindowTextLength(hWnd);
        if (length == 0) return string.Empty;
        StringBuilder sb = new StringBuilder(length + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<IntPtr> FindWindowsByProcess(string processName)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            try
            {
                var proc = System.Diagnostics.Process.GetProcessById((int)pid);
                if (proc.ProcessName == processName)
                {
                    string title = GetWindowTitle(hWnd);
                    if (!string.IsNullOrEmpty(title) && title != "PopupHost")
                        windows.Add(hWnd);
                }
            }
            catch {}
            return true;
        }, IntPtr.Zero);
        return windows;
    }
}
"@

if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
    Add-Type -TypeDefinition $WinApiSource -Language CSharp
}

# ============================================================================
# HELPERS
# ============================================================================

function Set-WindowForeground {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    if ([WinApi]::IsIconic($Handle)) {
        [WinApi]::ShowWindow($Handle, [WinApi]::SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 50
    }
    [WinApi]::ForceForeground($Handle) | Out-Null
    Start-Sleep -Milliseconds 50
}

function Set-WindowMaximizedOnMonitor {
    param(
        [IntPtr]$Handle,
        [System.Drawing.Rectangle]$MonitorBounds
    )
    if ($Handle -eq [IntPtr]::Zero) { return }

    Set-WindowForeground -Handle $Handle

    # Restore first: a maximized window ignores MoveWindow, so it would never
    # migrate to the target monitor.
    [WinApi]::ShowWindow($Handle, [WinApi]::SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds $Config.SettleDelayMs

    # Park it inside the target monitor, then maximize - maximize always fills
    # whichever monitor the window currently sits on.
    [WinApi]::MoveWindow($Handle,
        ($MonitorBounds.X + 60), ($MonitorBounds.Y + 60),
        1000, 700, $true) | Out-Null
    Start-Sleep -Milliseconds $Config.SettleDelayMs

    [WinApi]::ShowWindow($Handle, [WinApi]::SW_MAXIMIZE) | Out-Null
}

function Start-TerminalWindow {
    param([hashtable]$Cfg)

    $launcher = Join-Path $PSScriptRoot "launch-claude.ps1"

    # Build wt.exe args as one flat string; tab separator is ";".
    # Tab index N is passed to the launcher and determines the session slot.
    $segments = @()
    for ($i = 0; $i -lt $Cfg.Tabs.Count; $i++) {
        $tab   = $Cfg.Tabs[$i]
        $n     = $i + 1
        $dir   = $tab.WorkingDir.TrimEnd('\')
        $label = "$($tab.Title) / Claude $n"
        if ($i -eq 0) { $lead = "-w new" } else { $lead = "new-tab" }
        $segments += "$lead --title `"$($tab.Title)`" -d `"$dir`" `"$PwshExe`" -NoExit -ExecutionPolicy Bypass -Command `"& '$launcher' $n '$label' $($Cfg.WindowNum)`""
    }
    $wtArgs = $segments -join " ; "

    $wtPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"

    if ($DryRun) {
        Write-Host "pwsh   : $PwshExe" -ForegroundColor Gray
        Write-Host "wt.exe : $wtPath" -ForegroundColor Gray
        Write-Host ""
        foreach ($seg in $segments) {
            Write-Host $seg -ForegroundColor DarkGray
            Write-Host ""
        }
        Write-Host "joined length: $($wtArgs.Length) chars" -ForegroundColor Gray
        return
    }

    Start-Process $wtPath -ArgumentList $wtArgs
}

function Find-NewWTWindow {
    param([IntPtr[]]$ExistingWindows)
    foreach ($hwnd in [WinApi]::FindWindowsByProcess("WindowsTerminal")) {
        if ($ExistingWindows -notcontains $hwnd) { return $hwnd }
    }
    return [IntPtr]::Zero
}

# ============================================================================
# MAIN
# ============================================================================

function Invoke-DevLayout {
    Write-Host "DevLayout: launching 4 Claude tabs..." -ForegroundColor Cyan

    # Warn about missing repos rather than opening a tab in a dead directory.
    foreach ($tab in $Config.Tabs) {
        if (-not (Test-Path $tab.WorkingDir)) {
            Write-Warning "Repo not found: $($tab.WorkingDir)"
        }
    }

    if (-not (Test-Path $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }

    $monitors      = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
    $monitorIndex  = [Math]::Min($Config.TargetMonitor, $monitors.Count - 1)
    $targetMonitor = $monitors[$monitorIndex].WorkingArea

    # A stale HWND file would make tabs read a dead handle.
    Remove-Item (Join-Path $StateDir ".devlayout-hwnd-*") -ErrorAction SilentlyContinue

    $existing = [WinApi]::FindWindowsByProcess("WindowsTerminal")
    Start-TerminalWindow -Cfg $Config

    if ($DryRun) {
        Write-Host "DryRun: nothing launched." -ForegroundColor Yellow
        return
    }

    Write-Host "  waiting for window..." -ForegroundColor Gray
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        $handle = Find-NewWTWindow -ExistingWindows $existing
        if ($handle -ne [IntPtr]::Zero) { break }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Window not found; tabs may still be starting. Skipping positioning."
        return
    }

    Set-Content (Join-Path $StateDir ".devlayout-hwnd-$($Config.WindowNum)") $handle.ToInt64()
    Write-Host "    HWND: $($handle.ToInt64())" -ForegroundColor Gray

    Write-Host "  maximizing on monitor $($monitorIndex + 1) of $($monitors.Count)..." -ForegroundColor Cyan
    Set-WindowMaximizedOnMonitor -Handle $handle -MonitorBounds $targetMonitor

    Write-Host "DevLayout: complete." -ForegroundColor Green
}

Invoke-DevLayout
