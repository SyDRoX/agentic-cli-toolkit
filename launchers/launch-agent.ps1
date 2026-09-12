# Per-tab launcher for Cursor Agent CLI (`agent`). Used by the Cursor layout
# variants and by custom mixed-agent layouts from the Python UI.
#
# Sessions are scoped to the working directory via `--workspace`. `--continue`
# reopens the most recent chat for that workspace; if none exists, start fresh.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum
)

$cwd = (Get-Location).Path.TrimEnd('\')

Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray

# Trust the workspace so interactive trust prompts do not block tab startup.
# `--continue` fails when this workspace has no prior chat; start a new one then.
& agent --continue --trust --workspace $cwd
if ($LASTEXITCODE -ne 0) {
    Write-Host "[DevLayout] no saved Cursor Agent session for this repo; starting one." -ForegroundColor DarkGray
    & agent --trust --workspace $cwd
}

exit $LASTEXITCODE
