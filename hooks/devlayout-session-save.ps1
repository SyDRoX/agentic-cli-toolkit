# SessionStart hook: persist the active session id for a DevLayout tab slot.
#
# Fires on session start and on /resume, so whichever conversation a tab is
# actually showing becomes the one it reopens next launch. Capturing at START
# (not exit) is what makes this survive a force-close or an OS restart.
#
# No-ops unless DEVLAYOUT_WINDOW / DEVLAYOUT_TAB are set, i.e. unless the
# session was launched by DevLayout - so normal Claude sessions are untouched.

$windowNum = $env:DEVLAYOUT_WINDOW
$tabIndex  = $env:DEVLAYOUT_TAB
if (-not $windowNum -or -not $tabIndex) { exit 0 }

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $json = $raw | ConvertFrom-Json
} catch {
    exit 0
}

$sessionId = $json.session_id
if (-not $sessionId) { exit 0 }

$stateDir = Join-Path $env:USERPROFILE ".claude\dev-layout"
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$stateFile = Join-Path $stateDir ".devlayout-session-w$windowNum-t$tabIndex"
Set-Content -Path $stateFile -Value $sessionId -Encoding ASCII

exit 0
