#Requires -Version 5.1
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

# Only Claude pipes its hook JSON in; pi leaves stdin open, so reading it there would hang.
$hookInput = $null
if ($Agent -eq 'Claude' -and [Console]::IsInputRedirected) {
    try { $hookInput = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { }
}

function Test-AsyncAgentRunning($hookInput) {
    if (-not $hookInput -or -not $hookInput.transcript_path) { return $false }
    $path = [string]$hookInput.transcript_path
    if (-not (Test-Path -LiteralPath $path)) { return $false }

    $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
    } finally {
        $stream.Dispose()
    }

    $finished = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in [regex]::Matches($text, '<task-id>([A-Za-z0-9]+)</task-id>')) {
        $null = $finished.Add($m.Groups[1].Value)
    }

    # Background Bash is ignored: a server that never exits would mute every later Stop.
    foreach ($m in [regex]::Matches($text, '"isAsync":true[^{}]*?"agentId":"([A-Za-z0-9]+)"')) {
        if (-not $finished.Contains($m.Groups[1].Value)) { return $true }
    }

    return $false
}

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

function Stop-SessionPopups {
    # Close this session's popups. The pid file holds "<pid>|<start ticks>" per
    # popup, written by this script the moment it starts one, so a popup that is
    # still loading can be killed too. A process is only killed when its start
    # time still matches: popups that closed on their own leave their line
    # behind, and by the next call Windows may have given that pid to an
    # unrelated process.
    Set-Content $dismissFile "dismiss" -ErrorAction SilentlyContinue
    if (Test-Path $pidFile) {
        foreach ($line in (Get-Content $pidFile -ErrorAction SilentlyContinue)) {
            $parts = $line.Trim() -split '\|'
            $popupPid = 0
            if (-not [int]::TryParse($parts[0], [ref]$popupPid) -or $popupPid -le 0) { continue }
            $proc = Get-Process -Id $popupPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like 'powershell*') {
                $sameProcess = $true
                if ($parts.Count -gt 1) {
                    try { $sameProcess = ($proc.StartTime.ToUniversalTime().Ticks -eq [long]$parts[1]) } catch { $sameProcess = $false }
                }
                if ($sameProcess) { Stop-Process -Id $popupPid -Force -ErrorAction SilentlyContinue }
            }
            # A killed popup cannot release its own stack slot, so drop the
            # claim here or the stack keeps a hole.
            Get-ChildItem "$slotDir\*-$popupPid.slot" -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $dismissFile -Force -ErrorAction SilentlyContinue
}

function Stop-SessionFlash {
    if (Test-Path $hwndFile) {
        $savedHwnd = [IntPtr]::new([long](Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue))
        if ([WinHelper]::IsWindow($savedHwnd)) {
            [WinHelper]::StopFlash($savedHwnd)
        }
    }
}

try {
    switch ($Action) {
        "dismiss" {
            # The prompt that raised the popup went away without the user
            # necessarily being in this tab (a dialog that timed out), so close
            # the popup but do not re-capture the selected tab like resume does.
            Stop-SessionFlash
            Stop-SessionPopups
        }
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
            #
            # A finished background agent also fires UserPromptSubmit, with a
            # <task-notification> prompt and nobody typing - the foreground tab
            # is then some other session's, so re-capturing would steal it.
            $isTaskNotification = $hookInput -and "$($hookInput.prompt)".TrimStart().StartsWith('<task-notification>')
            if ($sessionId -ne "default" -and -not $isTaskNotification) {
                $saveHwnd = "$stateDir\save-hwnd.exe"
                if (Test-Path $saveHwnd) {
                    try { & $saveHwnd $sessionId 2>$null | Out-Null } catch { }
                }
            }

            Stop-SessionFlash
            Stop-SessionPopups
        }
        "attention" {
            # Stop also fires when a turn ends with agents still working in the background.
            $isAgentRunning = $false
            try { $isAgentRunning = Test-AsyncAgentRunning $hookInput } catch { }
            if ($isAgentRunning) { exit 0 }

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

            Stop-SessionPopups

            # Launch one popup per screen
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $screens = [System.Windows.Forms.Screen]::AllScreens
            for ($i = 0; $i -lt $screens.Count; $i++) {
                $popup = Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$popupScript`" -SessionId $sessionId -ScreenIndex $i -Agent $Agent" -WindowStyle Hidden -PassThru
                Add-Content -Path $pidFile -Value "$($popup.Id)|$($popup.StartTime.ToUniversalTime().Ticks)"
            }
        }
    }
} catch {}
exit 0
