#Requires -Version 5.1
<#
.SYNOPSIS
Launch an agent CLI in this Windows Terminal tab with notifications attached,
and close or restore every such tab.

.DESCRIPTION
Installed as bin\notify.ps1 and put on PATH by install.ps1, so it is typed as:

    notify claude --dangerously-skip-permissions
    notify codex -c model=gpt-5.6
    notify list
    notify close [-Force] [-DryRun]
    notify restore [-Snapshot <file>] [-DryRun]

Everything after the command name is handed to the agent untouched. That is why
this script has no param() block: PowerShell would bind flags such as -c or -r
to parameters of its own instead of passing them on.
#>

$cliArguments = @($args)

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
# Installed layout: <notify dir>\bin\notify.ps1. Run from the repository (tests),
# the state directory comes from AGENTIC_NOTIFY_DIR.
if ($env:AGENTIC_NOTIFY_DIR) {
    $notifyDir = $env:AGENTIC_NOTIFY_DIR
} elseif ((Split-Path $PSScriptRoot -Leaf) -eq 'bin') {
    $notifyDir = Split-Path $PSScriptRoot -Parent
} else {
    $notifyDir = Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify'
}

$registryScript = Join-Path $PSScriptRoot 'SessionRegistry.ps1'
if (-not (Test-Path -LiteralPath $registryScript)) { $registryScript = Join-Path $notifyDir 'SessionRegistry.ps1' }
if (-not (Test-Path -LiteralPath $registryScript)) {
    Write-Host "notify: SessionRegistry.ps1 not found. Re-run agentic-cli-notify\install.ps1." -ForegroundColor Red
    return
}
. $registryScript
# The registry resolves its directory on its own; keep both on the same one.
$savedNotifyDir = $env:AGENTIC_NOTIFY_DIR
$env:AGENTIC_NOTIFY_DIR = $notifyDir

$snapshotDir = Join-Path (Get-SessionRegistryDir) 'snapshots'
$devLayoutDir = Join-Path $env:USERPROFILE '.claude\dev-layout'

function Show-Usage {
    Write-Host 'notify <command> [arguments...]   launch an agent with notifications for this tab'
    Write-Host 'notify list                       show registered agent tabs'
    Write-Host 'notify close [-Force] [-DryRun]   save and close every registered agent tab'
    Write-Host 'notify restore [-Snapshot <file>] [-DryRun]'
    Write-Host '                                  reopen the tabs saved by the last close'
    Write-Host ''
    Write-Host 'Examples:'
    Write-Host '  notify claude --dangerously-skip-permissions'
    Write-Host '  notify pi --model gpt-5.6-luna:medium'
}

function Get-AgentKind {
    param([string]$Command)
    switch ([IO.Path]::GetFileNameWithoutExtension($Command).ToLowerInvariant()) {
        'claude'       { return 'Claude' }
        'codex'        { return 'Codex' }
        'pi'           { return 'Pi' }
        'agent'        { return 'Cursor' }
        'cursor-agent' { return 'Cursor' }
    }
    return 'Other'
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

function Invoke-TabSetup {
    # Capture this tab's window and position. Without arguments setup.ps1 reads
    # the foreground window, which is right for a command the user just typed.
    param([string]$TabIndex, [string]$Hwnd)

    $setup = Join-Path $notifyDir 'setup.ps1'
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-Host 'notify: setup.ps1 missing; popups start after the first prompt.' -ForegroundColor DarkYellow
        return
    }
    try {
        if ($Hwnd -and $TabIndex) {
            & $setup $TabIndex '' $Hwnd *> $null
        } elseif ($TabIndex) {
            & $setup $TabIndex *> $null
        } else {
            & $setup *> $null
        }
    } catch {
        Write-Host "notify: could not capture this tab ($($_.Exception.Message)). Popups start after the first prompt." -ForegroundColor DarkYellow
    }
}

function Start-RegisteredAgent {
    <#
    .PARAMETER RecordArguments
        Arguments to remember for the next restore. For a restored tab these are
        the ones the user typed, not the resume arguments built from them.
    .PARAMETER FallbackArguments
        Run when the first launch fails within seconds, which is what a rejected
        conversation id looks like.
    #>
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string[]]$RecordArguments,
        [string[]]$FallbackArguments,
        [bool]$HasFallback,
        [string]$TabIndex,
        [string]$Hwnd
    )

    if (-not $Arguments) { $Arguments = @() }
    if (-not $RecordArguments) { $RecordArguments = $Arguments }

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Host "notify: command '$Command' not found." -ForegroundColor Red
        $global:LASTEXITCODE = 127
        return
    }

    # An inherited marker makes Claude refuse to start as a nested session.
    Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue

    $kind = Get-AgentKind $Command
    $registered = $null
    if (Test-SessionKey $env:WT_SESSION) {
        Invoke-TabSetup -TabIndex $TabIndex -Hwnd $Hwnd
        $registered = Register-AgentSession -Agent $kind -Command $Command -Arguments $RecordArguments
        if ($kind -eq 'Other') {
            Write-Host "notify: tab registered. '$Command' has no notification adapter, so no popups." -ForegroundColor DarkGray
        } else {
            Write-Host "notify: $kind tab registered for notifications." -ForegroundColor DarkGray
        }
    } else {
        Write-Host 'notify: not inside Windows Terminal; launching without notifications.' -ForegroundColor DarkYellow
    }

    $startedAt = Get-Date
    try {
        & $Command @Arguments
        if ($HasFallback -and $LASTEXITCODE -ne 0 -and ((Get-Date) - $startedAt).TotalSeconds -lt 15) {
            Write-Host "notify: $Command rejected the saved conversation (exit $LASTEXITCODE). Starting without it." -ForegroundColor DarkYellow
            if (-not $FallbackArguments) { $FallbackArguments = @() }
            & $Command @FallbackArguments
        }
    } finally {
        # The agent is gone: nothing left in this tab to close or restore.
        if ($registered) { Unregister-AgentSession -SessionId $registered }
    }
}

# ---------------------------------------------------------------------------
# Win32
# ---------------------------------------------------------------------------

function Initialize-NotifyWin32 {
    # Only close and restore need this; a plain launch skips the compile.
    if ('AgenticNotifyWin' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class AgenticNotifyWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    const uint PROCESS_TERMINATE = 0x0001;

    // Exit code 0: Windows Terminal closes a tab whose shell exits cleanly, and
    // leaves a "[process exited with code N]" pane behind for anything else.
    public static bool Terminate(int pid, uint exitCode) {
        IntPtr process = OpenProcess(PROCESS_TERMINATE, false, pid);
        if (process == IntPtr.Zero) return false;
        try { return TerminateProcess(process, exitCode); }
        finally { CloseHandle(process); }
    }

    public static long[] TerminalWindows() {
        List<long> windows = new List<long>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd) || GetWindowTextLength(hWnd) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            try {
                if (Process.GetProcessById((int)pid).ProcessName == "WindowsTerminal") windows.Add(hWnd.ToInt64());
            } catch { }
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }
}
"@
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

function Invoke-List {
    $sessions = @(Get-AgentSessions)
    if ($sessions.Count -eq 0) {
        Write-Host 'notify: no registered agent tabs.'
        return
    }
    $sessions | Sort-Object hwnd, tabIndex | ForEach-Object {
        [pscustomobject]@{
            Agent        = $_.agent
            State        = $_.state
            Window       = if ($_.hwnd) { $_.hwnd } else { '?' }
            Tab          = if ($_.tabIndex) { $_.tabIndex } else { '?' }
            Conversation = if ($_.conversation) { $_.conversation } else { '-' }
            Source       = if ($_.launcher) { 'layout' } else { 'notify' }
            Directory    = $_.cwd
        }
    } | Format-Table -AutoSize | Out-Host
}

# ---------------------------------------------------------------------------
# close
# ---------------------------------------------------------------------------

function Get-ProcessTable {
    $table = @{}
    foreach ($process in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate)) {
        $table[[int]$process.ProcessId] = $process
    }
    return $table
}

function Get-TrueParent {
    # ParentProcessId outlives the parent, and Windows hands the number to new
    # processes. A "parent" that started after its child is such a reuse.
    param($Table, [int]$ProcessId)
    $process = $Table[$ProcessId]
    if (-not $process) { return $null }
    $parent = $Table[[int]$process.ParentProcessId]
    if (-not $parent) { return $null }
    if ($parent.CreationDate -and $process.CreationDate -and $parent.CreationDate -gt $process.CreationDate) { return $null }
    return $parent
}

function Get-TabRootProcess {
    # The process Windows Terminal started for the tab. Killing a shell nested
    # below it would leave the tab open.
    param($Table, [int]$ShellPid)
    $current = $ShellPid
    for ($depth = 0; $depth -lt 32; $depth++) {
        $parent = Get-TrueParent -Table $Table -ProcessId $current
        if (-not $parent) { break }
        if ($parent.Name -eq 'WindowsTerminal.exe') { return $current }
        $current = [int]$parent.ProcessId
    }
    return $ShellPid
}

function Get-ProcessDescendants {
    param($Table, [int]$RootPid)
    $children = @{}
    foreach ($process in $Table.Values) {
        $parent = Get-TrueParent -Table $Table -ProcessId ([int]$process.ProcessId)
        if (-not $parent) { continue }
        $key = [int]$parent.ProcessId
        if (-not $children.ContainsKey($key)) { $children[$key] = New-Object System.Collections.Generic.List[int] }
        $children[$key].Add([int]$process.ProcessId)
    }
    $found = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $children.ContainsKey($current)) { continue }
        foreach ($child in $children[$current]) {
            if ($found.Contains($child) -or $child -eq $RootPid) { continue }
            $found.Add($child)
            $queue.Enqueue($child)
        }
    }
    return $found.ToArray()
}

function Resolve-SessionWindow {
    # The window a tab lives in: the handle the hooks captured, else the handle
    # the layout engine saved for the tab's window slot.
    param($Session, [long[]]$LiveWindows)
    if ($Session.hwnd -and $LiveWindows -contains [long]$Session.hwnd) { return [long]$Session.hwnd }
    if ($Session.launcher -and $Session.launcherArgs -and @($Session.launcherArgs).Count -ge 3) {
        $slotHwnd = [long]0
        $slotFile = Join-Path $devLayoutDir ".devlayout-hwnd-$(@($Session.launcherArgs)[2])"
        if ((Test-Path -LiteralPath $slotFile) -and [long]::TryParse((Get-Content -LiteralPath $slotFile -Raw).Trim(), [ref]$slotHwnd)) {
            if ($LiveWindows -contains $slotHwnd) { return $slotHwnd }
        }
    }
    return [long]0
}

function Get-TabOrder {
    param($Session)
    if ($Session.tabIndex -gt 0) { return [int]$Session.tabIndex }
    $slotTab = 0
    if ($Session.launcher -and @($Session.launcherArgs).Count -ge 1 -and [int]::TryParse([string]@($Session.launcherArgs)[0], [ref]$slotTab)) { return $slotTab }
    return 999
}

function Invoke-Close {
    param([bool]$Force, [bool]$DryRun)

    Initialize-NotifyWin32
    $sessions = @(Get-AgentSessions)
    if ($sessions.Count -eq 0) {
        Write-Host 'notify: no registered agent tabs to close.'
        return
    }

    $table = Get-ProcessTable

    # Never close the tab this command runs in.
    $ownChain = New-Object System.Collections.Generic.List[int]
    $current = $PID
    for ($depth = 0; $depth -lt 32 -and $current; $depth++) {
        $ownChain.Add($current)
        $parent = Get-TrueParent -Table $table -ProcessId $current
        $current = if ($parent) { [int]$parent.ProcessId } else { 0 }
    }

    $liveWindows = [AgenticNotifyWin]::TerminalWindows()
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($session in $sessions) {
        $rootPid = Get-TabRootProcess -Table $table -ShellPid ([int]$session.shellPid)
        if ($ownChain.Contains($rootPid)) {
            Write-Host "notify: skipping this tab ($($session.agent) in $($session.cwd))." -ForegroundColor DarkGray
            continue
        }
        $targets.Add([pscustomobject]@{
            Session = $session
            RootPid = $rootPid
            Window  = Resolve-SessionWindow -Session $session -LiveWindows $liveWindows
            Order   = Get-TabOrder $session
        })
    }
    if ($targets.Count -eq 0) {
        Write-Host 'notify: no other registered agent tabs to close.'
        return
    }

    $busy = @($targets | Where-Object { $_.Session.state -eq 'busy' })
    if ($busy.Count -gt 0 -and -not $Force) {
        Write-Host "notify: $($busy.Count) tab(s) are mid-turn; nothing closed:" -ForegroundColor Yellow
        foreach ($target in $busy) {
            Write-Host "  $($target.Session.agent)  tab $($target.Order)  $($target.Session.cwd)" -ForegroundColor Yellow
        }
        Write-Host 'Wait for them, or run: notify close -Force' -ForegroundColor Yellow
        Write-Host '(A turn stopped with Escape also counts as mid-turn until the next prompt.)' -ForegroundColor DarkGray
        return
    }

    # --- snapshot --------------------------------------------------------
    $windows = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($targets | Group-Object Window | Sort-Object Name)) {
        $handle = [long]$group.Name
        $rect = $null
        $maximized = $false
        if ($handle -ne 0) {
            $pointer = [IntPtr]::new($handle)
            $maximized = [AgenticNotifyWin]::IsZoomed($pointer)
            if (-not [AgenticNotifyWin]::IsIconic($pointer)) {
                $raw = New-Object AgenticNotifyWin+RECT
                if ([AgenticNotifyWin]::GetWindowRect($pointer, [ref]$raw)) {
                    $rect = [ordered]@{ left = $raw.Left; top = $raw.Top; right = $raw.Right; bottom = $raw.Bottom }
                }
            }
        }
        $tabs = New-Object System.Collections.Generic.List[object]
        foreach ($target in ($group.Group | Sort-Object Order, { $_.Session.startedUtc })) {
            $session = $target.Session
            $tabs.Add([ordered]@{
                agent        = $session.agent
                command      = $session.command
                args         = @($session.args)
                cwd          = $session.cwd
                shell        = $session.shell
                title        = $session.title
                launcher     = $session.launcher
                launcherArgs = @($session.launcherArgs)
                conversation = $session.conversation
            })
        }
        $windows.Add([ordered]@{
            hwnd      = $handle
            maximized = $maximized
            rect      = $rect
            tabs      = $tabs.ToArray()
        })
    }
    $snapshot = [ordered]@{
        version    = 1
        createdUtc = [DateTime]::UtcNow.ToString('o')
        windows    = $windows.ToArray()
    }

    if ($DryRun) {
        Write-Host "notify close (dry run): $($targets.Count) tab(s) in $($windows.Count) window(s)"
        foreach ($window in $windows) {
            Write-Host "  window $($window.hwnd)$(if ($window.maximized) { ' (maximized)' })"
            foreach ($tab in $window.tabs) {
                $how = if ($tab.launcher) { "layout launcher $(Split-Path $tab.launcher -Leaf)" } else { "$($tab.command) $($tab.args -join ' ')" }
                Write-Host "    $($tab.agent)  $($tab.cwd)  [$how]  conversation: $(if ($tab.conversation) { $tab.conversation } else { 'none' })"
            }
        }
        Write-Host 'Dry run: nothing saved, nothing closed.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $snapshotDir)) { $null = New-Item -ItemType Directory -Path $snapshotDir -Force }
    $json = $snapshot | ConvertTo-Json -Depth 8
    $stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    Write-RegistryText (Join-Path $snapshotDir "$stamp.json") $json
    Write-RegistryText (Join-Path $snapshotDir 'last.json') $json
    # Keep the dated history short.
    Get-ChildItem -LiteralPath $snapshotDir -Filter '*.json' -File | Where-Object { $_.Name -ne 'last.json' } |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue

    # --- close -----------------------------------------------------------
    $closed = 0
    foreach ($target in $targets) {
        $descendants = Get-ProcessDescendants -Table $table -RootPid $target.RootPid
        if ([AgenticNotifyWin]::Terminate($target.RootPid, 0)) { $closed++ }
        # The tab only goes away once everything attached to its console is gone.
        foreach ($descendant in $descendants) {
            Stop-Process -Id $descendant -Force -ErrorAction SilentlyContinue
        }
        $sessionId = [string]$target.Session.sessionId
        Unregister-AgentSession -SessionId $sessionId
        foreach ($prefix in @('.hwnd-', '.tabindex-', '.tabname-', '.label-')) {
            Remove-Item -LiteralPath (Join-Path $notifyDir "$prefix$sessionId") -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "notify: closed $closed of $($targets.Count) tab(s) in $($windows.Count) window(s)." -ForegroundColor Green
    Write-Host 'Reopen them with: notify restore' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------

function ConvertTo-PsLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-WtText {
    # wt.exe splits its command line on ";" even inside quotes unless written "\;",
    # and a double quote would end the quoted argument.
    param([string]$Value)
    return $Value.Replace('"', '').Replace(';', '\;')
}

# wt.exe hands the caller's environment to the tabs it opens; see Invoke-CustomLayout.ps1.
$script:InheritedSessionVars = @(
    'CLAUDECODE', 'CLAUDE_PID', 'NO_COLOR',
    'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID',
    'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
    'CLAUDE_CODE_SHELL_LAUNCHER_SCRIPT'
)

function Invoke-Restore {
    param([string]$SnapshotPath, [bool]$DryRun)

    $usingLast = -not $SnapshotPath
    if ($usingLast) { $SnapshotPath = Join-Path $snapshotDir 'last.json' }
    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        if ($usingLast) { Write-Host 'notify: nothing to restore. Run notify close first, or pass -Snapshot <file>.' }
        else { Write-Host "notify: snapshot not found: $SnapshotPath" -ForegroundColor Red }
        return
    }
    $SnapshotPath = (Resolve-Path -LiteralPath $SnapshotPath).ProviderPath
    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $windows = @($snapshot.windows)
    if ($windows.Count -eq 0) {
        Write-Host 'notify: the snapshot holds no tabs.'
        return
    }

    # The new tabs read the snapshot themselves. Move last.json aside first, so a
    # second `notify restore` cannot open everything twice.
    if ($usingLast -and -not $DryRun) {
        $consumed = Join-Path $snapshotDir ("restored-" + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + ".json")
        Move-Item -LiteralPath $SnapshotPath -Destination $consumed -Force
        $SnapshotPath = $consumed
    }

    $registryDir = Get-SessionRegistryDir
    if (-not (Test-Path -LiteralPath $registryDir)) { $null = New-Item -ItemType Directory -Path $registryDir -Force }
    Get-ChildItem -LiteralPath $registryDir -Filter 'restore-*.hwnd' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } | Remove-Item -Force -ErrorAction SilentlyContinue

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $wtPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    $ownShell = (Get-Process -Id $PID).Path
    if (-not $DryRun) { Initialize-NotifyWin32 }

    $savedEnvironment = @{}
    if (-not $DryRun) {
        foreach ($name in $script:InheritedSessionVars) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ($null -eq $value) { continue }
            $persisted = [Environment]::GetEnvironmentVariable($name, 'User')
            if ($null -eq $persisted) { $persisted = [Environment]::GetEnvironmentVariable($name, 'Machine') }
            if ($null -eq $persisted) {
                $savedEnvironment[$name] = $value
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        $tabTotal = 0
        for ($w = 0; $w -lt $windows.Count; $w++) {
            $window = $windows[$w]
            $tabs = @($window.tabs)
            if ($tabs.Count -eq 0) { continue }

            $segments = @()
            $slotNumbers = @()
            for ($t = 0; $t -lt $tabs.Count; $t++) {
                $tab = $tabs[$t]
                $shell = if ($tab.shell -and (Test-Path -LiteralPath $tab.shell)) { [string]$tab.shell } else { $ownShell }
                $lead = if ($t -eq 0) { '-w new' } else { 'new-tab' }
                $title = if ($tab.title) { " --title `"$(ConvertTo-WtText ([string]$tab.title))`"" } else { '' }
                $command = "& $(ConvertTo-PsLiteral $PSCommandPath) __resume $(ConvertTo-PsLiteral $SnapshotPath) $w $t $token"
                # A trailing backslash would escape the closing quote; a bare drive
                # letter means "current directory on that drive", so name its root.
                $directory = ([string]$tab.cwd).TrimEnd('\')
                if ($directory -match '^[A-Za-z]:$') { $directory += '\.' }
                $segments += "$lead$title -d `"$(ConvertTo-WtText $directory)`" `"$shell`" -NoExit -ExecutionPolicy Bypass -Command `"$(ConvertTo-WtText $command)`""
                if ($tab.launcher -and @($tab.launcherArgs).Count -ge 3 -and $slotNumbers -notcontains @($tab.launcherArgs)[2]) {
                    $slotNumbers += @($tab.launcherArgs)[2]
                }
            }
            $tabTotal += $tabs.Count

            if ($DryRun) {
                Write-Host "window $($w + 1): $($tabs.Count) tab(s)$(if ($window.maximized) { ', maximized' })"
                for ($t = 0; $t -lt $tabs.Count; $t++) {
                    $tab = $tabs[$t]
                    if ($tab.launcher) {
                        Write-Host "  tab $($t + 1): $(Split-Path $tab.launcher -Leaf) $(@($tab.launcherArgs) -join ' ')  [$($tab.cwd)]"
                    } else {
                        $resume = Get-AgentResumeArguments -Agent $tab.agent -Arguments @($tab.args) -ConversationId $tab.conversation
                        Write-Host "  tab $($t + 1): $($tab.command) $($resume -join ' ')  [$($tab.cwd)]"
                    }
                }
                continue
            }

            # A stale handle would send layout tabs to a dead window.
            foreach ($slot in $slotNumbers) {
                Remove-Item -LiteralPath (Join-Path $devLayoutDir ".devlayout-hwnd-$slot") -Force -ErrorAction SilentlyContinue
            }

            $existing = [AgenticNotifyWin]::TerminalWindows()
            Start-Process $wtPath -ArgumentList ($segments -join ' ; ')

            $handle = [long]0
            for ($i = 0; $i -lt 40 -and $handle -eq 0; $i++) {
                Start-Sleep -Milliseconds 200
                foreach ($candidate in [AgenticNotifyWin]::TerminalWindows()) {
                    if ($existing -notcontains $candidate) { $handle = $candidate; break }
                }
            }
            if ($handle -eq 0) {
                Write-Host "notify: window $($w + 1) did not appear in time; its tabs capture themselves on the first prompt." -ForegroundColor DarkYellow
                continue
            }

            [IO.File]::WriteAllText((Join-Path $registryDir "restore-$token-$w.hwnd"), $handle.ToString())
            foreach ($slot in $slotNumbers) {
                if (-not (Test-Path -LiteralPath $devLayoutDir)) { $null = New-Item -ItemType Directory -Path $devLayoutDir -Force }
                [IO.File]::WriteAllText((Join-Path $devLayoutDir ".devlayout-hwnd-$slot"), $handle.ToString())
            }

            # Put the window back where it was. Moving it first also lands a
            # maximized window on the right monitor.
            if ($window.rect) {
                $pointer = [IntPtr]::new($handle)
                [void][AgenticNotifyWin]::ShowWindow($pointer, 9)
                [void][AgenticNotifyWin]::MoveWindow($pointer, [int]$window.rect.left, [int]$window.rect.top,
                    ([int]$window.rect.right - [int]$window.rect.left), ([int]$window.rect.bottom - [int]$window.rect.top), $true)
                if ($window.maximized) {
                    Start-Sleep -Milliseconds 150
                    [void][AgenticNotifyWin]::ShowWindow($pointer, 3)
                }
            }
            # Let this window settle so the next one can be told apart from it.
            if ($w -lt $windows.Count - 1) { Start-Sleep -Milliseconds 800 }
        }
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }

    if ($DryRun) {
        Write-Host 'Dry run: nothing launched.' -ForegroundColor Yellow
    } else {
        Write-Host "notify: restored $tabTotal tab(s) in $($windows.Count) window(s)." -ForegroundColor Green
    }
}

function Invoke-ResumeTab {
    # Runs inside each restored tab.
    param([string]$SnapshotPath, [int]$WindowIndex, [int]$TabNumber, [string]$Token)

    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $tab = @(@($snapshot.windows)[$WindowIndex].tabs)[$TabNumber]
    if (-not $tab) {
        Write-Host 'notify: this tab is missing from the snapshot.' -ForegroundColor Red
        return
    }

    # The restore command writes the new window's handle once the window is up.
    $hwnd = $null
    $hwndFile = Join-Path (Get-SessionRegistryDir) "restore-$Token-$WindowIndex.hwnd"
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-Path -LiteralPath $hwndFile) {
            $hwnd = (Get-Content -LiteralPath $hwndFile -Raw -ErrorAction SilentlyContinue)
            if ($hwnd) { $hwnd = $hwnd.Trim() }
            if ($hwnd) { break }
        }
        Start-Sleep -Milliseconds 200
    }
    $position = [string]($TabNumber + 1)

    if ($tab.launcher) {
        if (-not (Test-Path -LiteralPath $tab.launcher)) {
            Write-Host "notify: layout launcher not found: $($tab.launcher)" -ForegroundColor Red
            return
        }
        # The launcher registers the tab itself. Claude resolves its conversation
        # from its window slot; the others take the exact id from here.
        if ($hwnd) { Invoke-TabSetup -TabIndex $position -Hwnd $hwnd }
        if ($tab.conversation -and $tab.agent -ne 'Claude') { $env:AGENTIC_RESUME_ID = [string]$tab.conversation }
        try {
            $launcherArguments = @($tab.launcherArgs)
            & $tab.launcher @launcherArguments
        } finally {
            Remove-Item Env:AGENTIC_RESUME_ID -ErrorAction SilentlyContinue
        }
        return
    }

    $original = @($tab.args | ForEach-Object { [string]$_ })
    $resume = Get-AgentResumeArguments -Agent $tab.agent -Arguments $original -ConversationId $tab.conversation
    Start-RegisteredAgent -Command $tab.command -Arguments $resume -RecordArguments $original `
        -FallbackArguments $original -HasFallback ([bool]$tab.conversation) -TabIndex $position -Hwnd $hwnd
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

try {
    if ($cliArguments.Count -eq 0) {
        Show-Usage
        return
    }

    $verb = [string]$cliArguments[0]
    $rest = if ($cliArguments.Count -gt 1) { @($cliArguments[1..($cliArguments.Count - 1)] | ForEach-Object { [string]$_ }) } else { @() }

    switch -CaseSensitive ($verb) {
        { $_ -in @('help', '-h', '--help', '-?') } { Show-Usage; break }
        'list' { Invoke-List; break }
        'close' {
            Invoke-Close -Force ($rest -contains '-Force') -DryRun ($rest -contains '-DryRun')
            break
        }
        'restore' {
            $snapshotArgument = $null
            for ($i = 0; $i -lt $rest.Count; $i++) {
                if ($rest[$i] -eq '-Snapshot' -and ($i + 1) -lt $rest.Count) { $snapshotArgument = $rest[$i + 1] }
            }
            Invoke-Restore -SnapshotPath $snapshotArgument -DryRun ($rest -contains '-DryRun')
            break
        }
        '__resume' {
            Invoke-ResumeTab -SnapshotPath $rest[0] -WindowIndex ([int]$rest[1]) -TabNumber ([int]$rest[2]) -Token $rest[3]
            break
        }
        default {
            Start-RegisteredAgent -Command $verb -Arguments $rest
        }
    }
} finally {
    # This runs inside the user's own shell: leave its environment as found.
    if ($null -eq $savedNotifyDir) { Remove-Item Env:AGENTIC_NOTIFY_DIR -ErrorAction SilentlyContinue }
    else { $env:AGENTIC_NOTIFY_DIR = $savedNotifyDir }
}
