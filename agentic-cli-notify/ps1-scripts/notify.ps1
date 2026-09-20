param(
    [Parameter(Position=0)]
    [string]$Action = "attention",
    [ValidateSet('Claude', 'Codex', 'Pi', 'Cursor')]
    [string]$Agent = 'Claude'
)

# Use WT_SESSION to isolate state between terminal tabs for either CLI.
$sessionId = $env:WT_SESSION
if (-not $sessionId) { $sessionId = "default" }
$stateDir = $PSScriptRoot
$pidFile = "$stateDir\.popup-$sessionId.pid"
$dismissFile = "$stateDir\.dismiss-$sessionId"
$cooldownFile = "$stateDir\.cooldown-$sessionId"
$hwndFile = "$stateDir\.hwnd-$sessionId"
$tabIndexFile = "$stateDir\.tabindex-$sessionId"
$popupScript = "$stateDir\popup.ps1"
$slotDir = "$stateDir\.slots"

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinHelper {
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

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    public const uint FLASHW_ALL = 3;
    public const uint FLASHW_TIMERNOFG = 12;
    public const uint FLASHW_STOP = 0;

    public static void Flash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
        info.uCount = 0;
        info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }

    public static void StopFlash(IntPtr hwnd) {
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.hwnd = hwnd;
        info.dwFlags = FLASHW_STOP;
        info.uCount = 0;
        info.dwTimeout = 0;
        FlashWindowEx(ref info);
    }
}
"@ -ErrorAction SilentlyContinue

try {
    switch ($Action) {
        "resume" {
            # Self-heal the stored window + tab position.
            #
            # Tab index is positional, so closing or reordering a tab silently
            # invalidates it and click-to-switch then focuses the wrong tab.
            # UserPromptSubmit is the one moment this tab is provably the
            # selected tab in its window - the user just typed into it - so
            # re-capture here. Any close/reorder self-corrects on the next
            # prompt, with no fragile tab-name matching.
            #
            # save-hwnd.exe writes .hwnd-<id> / .tabindex-<id> directly when
            # given the session id, so concurrent tabs never race.
            if ($sessionId -ne "default") {
                $saveHwnd = "$stateDir\save-hwnd.exe"
                if (Test-Path $saveHwnd) {
                    try { & $saveHwnd $sessionId 2>$null | Out-Null } catch { }
                }
            }

            # Stop flash on saved HWND
            if (Test-Path $hwndFile) {
                $savedHwnd = [IntPtr]::new([long](Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue))
                if ([WinHelper]::IsWindow($savedHwnd)) {
                    [WinHelper]::StopFlash($savedHwnd)
                }
            }

            # Dismiss this session's popups via signal file + process kill
            Set-Content $dismissFile "dismiss" -ErrorAction SilentlyContinue
            if (Test-Path $pidFile) {
                $oldPids = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($oldPids) {
                    foreach ($p in $oldPids) {
                        if ($p.Trim()) {
                            Stop-Process -Id $p.Trim() -Force -ErrorAction SilentlyContinue
                            # A killed popup cannot release its own stack slot,
                            # so drop the claim here or the stack keeps a hole.
                            Get-ChildItem "$slotDir\*-$($p.Trim()).slot" -ErrorAction SilentlyContinue |
                                Remove-Item -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $dismissFile -Force -ErrorAction SilentlyContinue
        }
        "attention" {
            # Read saved HWND for this session
            $hwnd = [IntPtr]::Zero
            if (Test-Path $hwndFile) {
                $val = (Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue)
                if ($val) { $hwnd = [IntPtr]::new([long]$val) }
            }
            if ($hwnd -eq [IntPtr]::Zero -or -not [WinHelper]::IsWindow($hwnd)) { exit 0 }

            [WinHelper]::Flash($hwnd)

            # Read the actual tab name from WT via UI Automation
            try {
                Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
                Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
                $tabIdx = $null
                if (Test-Path $tabIndexFile) {
                    $tabIdx = [int](Get-Content $tabIndexFile -Raw -ErrorAction SilentlyContinue)
                }
                if ($tabIdx -and [WinHelper]::IsWindow($hwnd)) {
                    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
                    $tabs = $root.FindAll(
                        [System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.PropertyCondition]::new(
                            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                            [System.Windows.Automation.ControlType]::TabItem
                        )
                    )
                    if ($tabIdx -ge 1 -and $tabIdx -le $tabs.Count) {
                        $rawName = $tabs[$tabIdx - 1].Current.Name
                        # Agents prefix the tab with a glyph - pi uses a pi
                        # character, so "pi - PotatoSandwich". Dropping the
                        # non-ASCII glyph leaves the separator behind and the
                        # popup would read "Pi - - PotatoSandwich", so strip
                        # any leading separator as well.
                        $tabName = ($rawName -replace '[^\x20-\x7E]', '') -replace '^[\s\-:|]+', ''
                        $tabName = $tabName.Trim()
                        if ($tabName) {
                            $labelFile = "$stateDir\.label-$sessionId"
                            $existingLabel = ""
                            if (Test-Path $labelFile) {
                                $existingLabel = (Get-Content $labelFile -Raw -ErrorAction SilentlyContinue).Trim()
                            }
                            # Keep window prefix (e.g. "Repos") if present
                            if ($existingLabel -match '^(.+?) / ') {
                                $prefix = $Matches[1]
                                $newLabel = "$prefix / $tabName"
                            } else {
                                $newLabel = $tabName
                            }
                            Set-Content $labelFile $newLabel
                        }
                    }
                }
            } catch {}

            # Kill any existing popups for this session
            Set-Content $dismissFile "dismiss" -ErrorAction SilentlyContinue
            if (Test-Path $pidFile) {
                $oldPids = Get-Content $pidFile -ErrorAction SilentlyContinue
                if ($oldPids) {
                    foreach ($p in $oldPids) {
                        if ($p.Trim()) {
                            Stop-Process -Id $p.Trim() -Force -ErrorAction SilentlyContinue
                            # A killed popup cannot release its own stack slot,
                            # so drop the claim here or the stack keeps a hole.
                            Get-ChildItem "$slotDir\*-$($p.Trim()).slot" -ErrorAction SilentlyContinue |
                                Remove-Item -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
            Remove-Item $dismissFile -Force -ErrorAction SilentlyContinue

            # Launch one popup per screen
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $screens = [System.Windows.Forms.Screen]::AllScreens
            for ($i = 0; $i -lt $screens.Count; $i++) {
                Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$popupScript`" -SessionId $sessionId -ScreenIndex $i -Agent $Agent" -WindowStyle Hidden
            }
        }
    }
} catch {}
exit 0
