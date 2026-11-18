# Per-tab launcher for Cursor Agent CLI (`agent`). Used by the Cursor layout
# variants and by custom mixed-agent layouts from the Python UI.
#
# Sessions are scoped to the working directory via `--workspace`. `--continue`
# reopens the most recent chat for that workspace; if none exists, start fresh.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum,
    # Model/Effort/ContextWindow: cursor agent has no equivalent CLI flags, unused.
    [Parameter(Position = 3)][string]$Model,
    [Parameter(Position = 4)][string]$Effort,
    [Parameter(Position = 5)][string]$ContextWindow
)

$cwd = (Get-Location).Path.TrimEnd('\')

Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray

# Optional agentic-cli-notify registry, so `notify close` / `notify restore`
# cover this tab. `notify restore` passes the exact chat to reopen in
# AGENTIC_RESUME_ID; cleared here so nothing the agent starts inherits it.
$resumeId = $env:AGENTIC_RESUME_ID
Remove-Item Env:AGENTIC_RESUME_ID -ErrorAction SilentlyContinue
$registeredSession = $null
$sessionRegistry = Join-Path $env:USERPROFILE ".claude\hooks\agentic-cli-notify\SessionRegistry.ps1"
if (Test-Path $sessionRegistry) {
    . $sessionRegistry
    $registeredSession = Register-AgentSession -Agent Cursor -Command agent -Title ($Label -replace ' / [^/]*$', '') `
        -Launcher $PSCommandPath -LauncherArguments @($TabIndex, $Label, $WindowNum, $Model, $Effort, $ContextWindow)
}

try {
    $resumed = $false
    if ($resumeId) {
        $startedAt = Get-Date
        & agent --resume $resumeId --trust --workspace $cwd
        # Only a quick failure means the id was rejected.
        $resumed = -not ($LASTEXITCODE -ne 0 -and ((Get-Date) - $startedAt).TotalSeconds -lt 15)
    }

    if (-not $resumed) {
        # Trust the workspace so interactive trust prompts do not block tab startup.
        # `--continue` fails when this workspace has no prior chat; start a new one then.
        # Only a quick failure means that, not a long session that exited non-zero.
        $startedAt = Get-Date
        & agent --continue --trust --workspace $cwd
        if ($LASTEXITCODE -ne 0 -and ((Get-Date) - $startedAt).TotalSeconds -lt 15) {
            Write-Host "[DevLayout] no saved Cursor Agent session for this repo; starting one." -ForegroundColor DarkGray
            & agent --trust --workspace $cwd
        }
    }
} finally {
    if ($registeredSession) { Unregister-AgentSession -SessionId $registeredSession }
}

exit $LASTEXITCODE
