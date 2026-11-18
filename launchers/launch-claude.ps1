# Per-tab launcher for Claude Code - used by agentic-cli-toolkit.
# Args: $args[0] = tab index (1-4), $args[1] = label, $args[2] = window number,
#       $args[3] = model, $args[4] = effort, $args[5] = context window, $args[6] = response style
#
# SESSION RESUME (the point of this script)
# -----------------------------------------
# Each (window, tab) slot owns a deterministic UUID derived from its position,
# so a slot maps to the same conversation across relaunches with no state at
# all. A state file, written by the SessionStart hook, overrides that UUID so a
# manual /resume inside Claude sticks on the next launch.
#
#   Priority: state file > deterministic slot UUID > brand-new session
#
# Each tab has its own working directory, so each resolves its own project dir
# under ~/.claude/projects, and session ids are only ever looked up inside the
# project dir belonging to that tab's repo.
#
# Resolution logic lives in SessionSlot.ps1, shared with Test-Resume.ps1.

# Clear inherited CLAUDECODE env var to prevent a nested-session error
Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue

$tabIndex      = $args[0]
$label         = $args[1]
if ($args[2]) { $windowNum = $args[2] } else { $windowNum = 1 }
$model         = $args[3]
$effort        = $args[4]
$contextWindow = $args[5]
$style         = $args[6]

. (Join-Path $PSScriptRoot "..\ps1-scripts\SessionSlot.ps1")
. (Join-Path $PSScriptRoot "..\ps1-scripts\ResponseStyle.ps1")

$StateDir = Join-Path $env:USERPROFILE ".claude\dev-layout"
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Optional agentic-cli-notify integration
# ---------------------------------------------------------------------------
# Upstream calls this unconditionally and assumes ~/.claude/hooks/agentic-cli-notify
# exists. It does not ship with dev-layout, so guard it: when absent, skip it
# entirely instead of erroring and burning 15s polling for an HWND nobody reads.
$notifySetup = Join-Path $env:USERPROFILE ".claude\hooks\agentic-cli-notify\setup.ps1"
if (Test-Path $notifySetup) {
    $hwnd = $null
    $hwndFile = Join-Path $StateDir ".devlayout-hwnd-$windowNum"
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Path $hwndFile) {
            $hwnd = (Get-Content $hwndFile -Raw -ErrorAction SilentlyContinue)
            if ($hwnd) { $hwnd = $hwnd.Trim() }
            if ($hwnd) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($tabIndex -and $label -and $hwnd) {
        & $notifySetup $tabIndex $label $hwnd
    } elseif ($tabIndex -and $label) {
        & $notifySetup $tabIndex $label
    }
}

# ---------------------------------------------------------------------------
# Resolve this slot's session
# ---------------------------------------------------------------------------

$cwd = (Get-Location).Path.TrimEnd('\')

$slot = Resolve-SlotResume -WindowNum $windowNum -TabIndex $tabIndex `
                           -WorkingDir $cwd -StateDir $StateDir

# ---------------------------------------------------------------------------
# Model / effort / context window
# ---------------------------------------------------------------------------
# [1m] is the only context suffix Claude accepts (verified against the binary:
# claude-*[1m] only, no [2m]/[256k]), so context size is not a per-tab choice.
$extraArgs = @()
$resolvedModel = $model
if ($model -and $contextWindow -eq "default[1m]") { $resolvedModel = "$model[1m]" }
if ($resolvedModel) { $extraArgs += @("--model", $resolvedModel) }
if ($effort)         { $extraArgs += @("--effort", $effort) }

# ---------------------------------------------------------------------------
# Response style
# ---------------------------------------------------------------------------
# An installed output style is selected through a per-style settings file, so it
# replaces the user's global outputStyle for this tab only. Without the installed
# file the same rules are appended to the system prompt instead. Claude records the
# system prompt per conversation, so on a resumed conversation a changed style
# arrives as a later instruction block, not as a new system prompt.
$resolvedStyle = Resolve-ResponseStyle -Name $style
if ($resolvedStyle) {
    if (Test-Path -LiteralPath (Get-ClaudeOutputStylePath -Style $resolvedStyle)) {
        # A file, not inline JSON: Windows PowerShell 5.1 strips the double quotes
        # from a JSON string passed as a native argument.
        $styleSettings = Join-Path $StateDir ".devlayout-style-$($resolvedStyle.Key).json"
        $styleJson = '{"outputStyle":"' + $resolvedStyle.Label + '"}'
        [System.IO.File]::WriteAllText($styleSettings, $styleJson, (New-Object System.Text.UTF8Encoding($false)))
        $extraArgs += @("--settings", $styleSettings)
    } else {
        Write-Warning "[DevLayout] output style '$($resolvedStyle.Label)' is not installed; appending its rules instead. Run ps1-scripts\Install-ResponseStyles.ps1 for the /style command and the statusline name."
        $extraArgs += @("--append-system-prompt-file", $resolvedStyle.RulesPath)
    }
    # The caveman plugin injects its own rules at session start unless told not to.
    $env:CAVEMAN_DEFAULT_MODE = if ($resolvedStyle.Key -eq "caveman") { "full" } else { "off" }
    $env:DEVLAYOUT_STYLE = $resolvedStyle.Key
    # A /style switch made earlier in this conversation must not outlive the relaunch.
    foreach ($sessionId in @($slot.ResumeId, $slot.DefaultSessionId)) {
        if ($sessionId) {
            Remove-Item -LiteralPath (Join-Path $env:USERPROFILE ".claude\style-sessions\$sessionId") -ErrorAction SilentlyContinue
        }
    }
} else {
    Remove-Item Env:DEVLAYOUT_STYLE -ErrorAction SilentlyContinue
}

# Let the SessionStart hook know which slot to persist into. Set before Claude
# launches so the hook fires with the slot already identified.
$env:DEVLAYOUT_WINDOW = $windowNum
$env:DEVLAYOUT_TAB    = $tabIndex
# Every process Claude starts inherits these, including a headless `claude -p`
# run from a tool call. The hook only records a session whose Claude process is
# a direct child of this launcher.
$env:DEVLAYOUT_LAUNCHER_PID = $PID

# Claude Code does not expose the effort level to the statusline command, so
# pass it through the environment for gsd-statusline.js to display.
if ($effort) { $env:DEVLAYOUT_EFFORT = $effort }
else { Remove-Item Env:DEVLAYOUT_EFFORT -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

Write-Host "[DevLayout] $label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray
if ($resolvedStyle) { Write-Host "[DevLayout] style: $($resolvedStyle.Label)" -ForegroundColor DarkGray }

# Self-heal: if Claude rejects the session (deleted or corrupt transcript, or a
# slot id already in use), fall back to a fresh session rather than leaving a
# dead tab. The SessionStart hook records the new id, so the next launch resumes
# that instead. Only a quick failure counts as a rejection: a session that ran
# for a while and then exited non-zero must not be replaced by an empty one.
# Optional agentic-cli-notify registry, so `notify close` / `notify restore`
# cover this tab. Restore reruns this launcher, so the slot rules above still
# pick the conversation.
$registeredSession = $null
$sessionRegistry = Join-Path $env:USERPROFILE ".claude\hooks\agentic-cli-notify\SessionRegistry.ps1"
if (Test-Path $sessionRegistry) {
    . $sessionRegistry
    $registeredSession = Register-AgentSession -Agent Claude -Command claude -Title ("$label" -replace ' / [^/]*$', '') `
        -Launcher $PSCommandPath -LauncherArguments @("$tabIndex", "$label", "$windowNum", "$model", "$effort", "$contextWindow", "$style")
}

$startedAt = Get-Date
try {
    if ($slot.ResumeId) {
        Write-Host "[DevLayout] resuming $($slot.ResumeId) via $($slot.Source)" -ForegroundColor DarkGray
        & claude --dangerously-skip-permissions --resume $slot.ResumeId @extraArgs
    } else {
        Write-Host "[DevLayout] new session, pinned to $($slot.DefaultSessionId)" -ForegroundColor DarkGray
        & claude --dangerously-skip-permissions --session-id $slot.DefaultSessionId @extraArgs
    }
    if ($LASTEXITCODE -ne 0 -and ((Get-Date) - $startedAt).TotalSeconds -lt 15) {
        Write-Warning "[DevLayout] Claude rejected the session (exit $LASTEXITCODE). Starting a fresh session; it will be remembered for next launch."
        & claude --dangerously-skip-permissions @extraArgs
    }
} finally {
    if ($registeredSession) { Unregister-AgentSession -SessionId $registeredSession }
}

# The shell stays open (-NoExit). Do not let a later manual `claude` in it
# overwrite this slot.
Remove-Item Env:DEVLAYOUT_WINDOW, Env:DEVLAYOUT_TAB, Env:DEVLAYOUT_LAUNCHER_PID -ErrorAction SilentlyContinue
