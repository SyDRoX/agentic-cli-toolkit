#Requires -Version 5.1
<#
.SYNOPSIS
    Shared launcher engine: opens ONE Windows Terminal window with a Claude Code
    tab per configured repo, maximized on a target monitor.
.DESCRIPTION
    Dot-source this file and call Invoke-LayoutWindow with a layout hashtable.
    It is the generalized form of the logic in DevLayout.ps1, extracted so that
    several layouts (one per game, or a combined one) can share it instead of
    copying the Win32 plumbing.

    A layout hashtable looks like this:

        @{
            Name          = "PotatoSandwich x3"   # printed on launch only
            WindowNum     = 2                     # SESSION NAMESPACE, see below
            TargetMonitor = 0                     # 0 = leftmost monitor
            SettleDelayMs = 150
            Tabs = @(
                @{ Title = "PS1"; WorkingDir = "C:\Repos\PotatoSandwich" }
                ...
            )
        }

    WindowNum is load-bearing. Session slot UUIDs are derived from
    "devlayout-w<WindowNum>-t<TabIndex>", so two layouts that share a WindowNum
    would fight over the same saved conversations. Give every layout its own
    number and never renumber one that is already in use.

    Tab order is load-bearing for the same reason: tab N owns slot w<N>-t<N>, so
    reordering the list reassigns which conversation each tab reopens. Appending
    a tab is safe; reordering existing ones is not.
.NOTES
    Adapted from DevLayout.ps1 (itself adapted from SyDroX/dev-layout, MIT).
#>

# ============================================================================
# ENVIRONMENT
# ============================================================================

function Get-PwshPath {
    <#
    .SYNOPSIS
        Full path to pwsh.exe.
    .DESCRIPTION
        wt.exe is a UWP app and will not inherit PATH changes made in the
        current process, so the launcher has to hand it an absolute path. The
        machine and user PATH values are read from the registry rather than
        $env:Path so a freshly installed PowerShell 7 is found without a
        re-login.
    #>
    $registryPath = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                    [Environment]::GetEnvironmentVariable("Path", "User") + ";" + $env:Path

    return ($registryPath.Split(';') |
        Where-Object { $_ -and (Test-Path (Join-Path $_ "pwsh.exe") -ErrorAction SilentlyContinue) } |
        Select-Object -First 1 |
        ForEach-Object { Join-Path $_ "pwsh.exe" })
}

# ============================================================================
# WINDOWS API
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms

$LayoutWinApiSource = @"
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
    Add-Type -TypeDefinition $LayoutWinApiSource -Language CSharp
}

# ============================================================================
# HELPERS
# ============================================================================

function Set-LayoutWindowForeground {
    param([IntPtr]$Handle)
    if ($Handle -eq [IntPtr]::Zero) { return }
    if ([WinApi]::IsIconic($Handle)) {
        [WinApi]::ShowWindow($Handle, [WinApi]::SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 50
    }
    [WinApi]::ForceForeground($Handle) | Out-Null
    Start-Sleep -Milliseconds 50
}

function Set-LayoutWindowMaximized {
    param(
        [IntPtr]$Handle,
        [System.Drawing.Rectangle]$MonitorBounds,
        [int]$SettleDelayMs = 150
    )
    if ($Handle -eq [IntPtr]::Zero) { return }

    Set-LayoutWindowForeground -Handle $Handle

    # Restore first: a maximized window ignores MoveWindow, so it would never
    # migrate to the target monitor.
    [WinApi]::ShowWindow($Handle, [WinApi]::SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds $SettleDelayMs

    # Park it inside the target monitor, then maximize - maximize always fills
    # whichever monitor the window currently sits on.
    [WinApi]::MoveWindow($Handle,
        ($MonitorBounds.X + 60), ($MonitorBounds.Y + 60),
        1000, 700, $true) | Out-Null
    Start-Sleep -Milliseconds $SettleDelayMs

    [WinApi]::ShowWindow($Handle, [WinApi]::SW_MAXIMIZE) | Out-Null
}

function Find-NewTerminalWindow {
    param([IntPtr[]]$ExistingWindows)
    foreach ($hwnd in [WinApi]::FindWindowsByProcess("WindowsTerminal")) {
        if ($ExistingWindows -notcontains $hwnd) { return $hwnd }
    }
    return [IntPtr]::Zero
}

function Resolve-TabLauncher {
    <#
    .SYNOPSIS
        Resolve AgentName + launcher script path for one tab.
    .DESCRIPTION
        Per-tab AgentName / LauncherScript override the layout defaults. That
        lets a single window mix Claude, Codex, Pi, and Cursor Agent tabs.
    #>
    param(
        [hashtable]$Layout,
        [hashtable]$Tab
    )

    $agent = if ($Tab.AgentName) { $Tab.AgentName } elseif ($Layout.AgentName) { $Layout.AgentName } else { "Claude" }
    $scriptName = if ($Tab.LauncherScript) { $Tab.LauncherScript } elseif ($Layout.LauncherScript) { $Layout.LauncherScript } else { "launch-claude.ps1" }
    $launcherPath = Join-Path $PSScriptRoot $scriptName

    return @{
        AgentName    = $agent
        ScriptName   = $scriptName
        LauncherPath = $launcherPath
    }
}

function Build-LayoutSegments {
    <#
    .SYNOPSIS
        One wt.exe argument segment per tab.
    .DESCRIPTION
        Each segment starts a pwsh host that runs the tab's launcher script with
        the tab index, a display label and the window number. Claude's launcher
        resolves the session for slot w<WindowNum>-t<TabIndex>; other agents
        resume by working directory.
    #>
    param(
        [hashtable]$Layout,
        [string]$PwshExe
    )

    $segments = @()
    for ($i = 0; $i -lt $Layout.Tabs.Count; $i++) {
        $tab   = $Layout.Tabs[$i]
        $n     = $i + 1
        $dir   = $tab.WorkingDir.TrimEnd('\')
        $resolved = Resolve-TabLauncher -Layout $Layout -Tab $tab
        $label = "$($tab.Title) / $($resolved.AgentName) $n"
        if ($i -eq 0) { $lead = "-w new" } else { $lead = "new-tab" }
        $segments += "$lead --title `"$($tab.Title)`" -d `"$dir`" `"$PwshExe`" -NoExit -ExecutionPolicy Bypass -Command `"& '$($resolved.LauncherPath)' $n '$label' $($Layout.WindowNum)`""
    }
    return $segments
}

# ============================================================================
# MAIN
# ============================================================================

function Invoke-LayoutWindow {
    <#
    .SYNOPSIS
        Launch one Windows Terminal window for a layout and maximize it.
    .PARAMETER Layout
        Layout hashtable: Name, WindowNum, Tabs, and optionally TargetMonitor
        and SettleDelayMs.
    .PARAMETER DryRun
        Print the wt.exe segments and exit without launching anything.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Layout,
        [switch]$DryRun
    )

    if (-not $Layout.Tabs -or $Layout.Tabs.Count -eq 0) {
        Write-Error "Layout '$($Layout.Name)' has no tabs."
        return
    }
    if (-not $Layout.WindowNum) {
        Write-Error "Layout '$($Layout.Name)' has no WindowNum; session slots would collide."
        return
    }
    if (-not $Layout.ContainsKey('TargetMonitor')) { $Layout.TargetMonitor = 0 }
    if (-not $Layout.SettleDelayMs)                { $Layout.SettleDelayMs = 150 }

    $pwshExe = Get-PwshPath
    if (-not $pwshExe) {
        Write-Error "pwsh.exe not found. Install PowerShell 7: winget install Microsoft.PowerShell"
        return
    }

    $stateDir = if ($Layout.StateDir) { $Layout.StateDir } else { Join-Path $env:USERPROFILE ".claude\dev-layout" }

    $agents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($tab in $Layout.Tabs) {
        $resolved = Resolve-TabLauncher -Layout $Layout -Tab $tab
        [void]$agents.Add($resolved.AgentName)
        if (-not (Test-Path $resolved.LauncherPath)) {
            Write-Error "$($resolved.ScriptName) not found next to LayoutEngine.ps1 ($PSScriptRoot)."
            return
        }
        if (-not (Test-Path $tab.WorkingDir)) {
            Write-Warning "Repo not found: $($tab.WorkingDir)"
        }
    }

    $agentLabel = if ($agents.Count -eq 1) { @($agents)[0] } else { "mixed" }
    Write-Host "$($Layout.Name): launching $($Layout.Tabs.Count) $agentLabel tabs (window slot $($Layout.WindowNum))..." -ForegroundColor Cyan

    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $segments = Build-LayoutSegments -Layout $Layout -PwshExe $pwshExe
    $wtArgs   = $segments -join " ; "
    $wtPath   = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"

    if ($DryRun) {
        Write-Host "pwsh   : $pwshExe" -ForegroundColor Gray
        Write-Host "wt.exe : $wtPath" -ForegroundColor Gray
        Write-Host ""
        foreach ($seg in $segments) {
            Write-Host $seg -ForegroundColor DarkGray
            Write-Host ""
        }
        Write-Host "joined length: $($wtArgs.Length) chars" -ForegroundColor Gray
        Write-Host "DryRun: nothing launched." -ForegroundColor Yellow
        return
    }

    $monitors      = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
    $monitorIndex  = [Math]::Min($Layout.TargetMonitor, $monitors.Count - 1)
    $targetMonitor = $monitors[$monitorIndex].WorkingArea

    # A stale HWND file would make tabs read a dead handle.
    Remove-Item (Join-Path $stateDir ".devlayout-hwnd-$($Layout.WindowNum)") -ErrorAction SilentlyContinue

    $existing = [WinApi]::FindWindowsByProcess("WindowsTerminal")
    Start-Process $wtPath -ArgumentList $wtArgs

    Write-Host "  waiting for window..." -ForegroundColor Gray
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        $handle = Find-NewTerminalWindow -ExistingWindows $existing
        if ($handle -ne [IntPtr]::Zero) { break }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Window not found; tabs may still be starting. Skipping positioning."
        return
    }

    Set-Content (Join-Path $stateDir ".devlayout-hwnd-$($Layout.WindowNum)") $handle.ToInt64()
    Write-Host "    HWND: $($handle.ToInt64())" -ForegroundColor Gray

    Write-Host "  maximizing on monitor $($monitorIndex + 1) of $($monitors.Count)..." -ForegroundColor Cyan
    Set-LayoutWindowMaximized -Handle $handle -MonitorBounds $targetMonitor -SettleDelayMs $Layout.SettleDelayMs

    Write-Host "$($Layout.Name): complete." -ForegroundColor Green
}
