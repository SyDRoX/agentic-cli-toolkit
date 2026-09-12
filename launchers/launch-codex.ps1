# Per-tab launcher for Codex CLI. Used by the Codex layout variants.
# Codex filters `resume --last` by the current working directory, giving each
# repository tab its own durable conversation.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum
)

$cwd = (Get-Location).Path.TrimEnd('\')

Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray

# `--last` exits non-zero when this repo has no saved interactive session.
# Start a new one then; the next launch resumes it automatically.
& codex resume --last -C $cwd
if ($LASTEXITCODE -ne 0) {
    Write-Host "[DevLayout] no saved Codex session for this repo; starting one." -ForegroundColor DarkGray
    & codex -C $cwd
}

exit $LASTEXITCODE
