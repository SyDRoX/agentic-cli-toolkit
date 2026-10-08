# SessionStart hook: persist the active session id for a DevLayout tab slot.
#
# Fires on session start and on /resume, so whichever conversation a tab is
# actually showing becomes the one it reopens next launch. Capturing at START
# (not exit) is what makes this survive a force-close or an OS restart.
#
# No-ops unless DEVLAYOUT_WINDOW / DEVLAYOUT_TAB are set, i.e. unless the
# session was launched by DevLayout - so normal Claude sessions are untouched.
# Those variables are inherited by everything Claude starts, so a nested
# `claude -p` would also see them. DEVLAYOUT_LAUNCHER_PID tells the two apart:
# only the Claude process the launcher started directly may write the slot.

$windowNum = $env:DEVLAYOUT_WINDOW
$tabIndex  = $env:DEVLAYOUT_TAB
if (-not $windowNum -or -not $tabIndex) { exit 0 }

$launcherPid = $env:DEVLAYOUT_LAUNCHER_PID
if ($launcherPid) {
    try {
        $parents = @{}
        $names = @{}
        foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name)) {
            $parents[[int]$p.ProcessId] = [int]$p.ParentProcessId
            $names[[int]$p.ProcessId] = $p.Name
        }
        # Walk up from this hook to the nearest Claude process.
        $current = $PID
        for ($i = 0; $i -lt 16 -and $parents.ContainsKey($current); $i++) {
            $current = $parents[$current]
            if ($names[$current] -like 'claude*') {
                if ($parents[$current] -ne [int]$launcherPid) { exit 0 }
                break
            }
        }
    } catch {
        # Process lookup failed: fall through and record, as before this check.
    }
}

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $json = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$sessionId = $json.session_id
if (-not $sessionId) { exit 0 }

try {
    $stateDir = Join-Path $env:USERPROFILE ".claude\dev-layout"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    $stateFile = Join-Path $stateDir ".devlayout-session-w$windowNum-t$tabIndex"
    Set-Content -Path $stateFile -Value $sessionId -Encoding ASCII
} catch {
    # A hook must never surface an error to the agent CLI.
}

exit 0
