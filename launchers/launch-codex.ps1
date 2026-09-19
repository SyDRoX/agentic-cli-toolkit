# Per-tab launcher for Codex CLI. Used by the Codex layout variants.
# Codex filters `resume --last` by the current working directory, giving each
# repository tab its own durable conversation.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum,
    [Parameter(Position = 3)][string]$Model,
    [Parameter(Position = 4)][string]$Effort,
    [Parameter(Position = 5)][string]$ContextWindow
)

$cwd = (Get-Location).Path.TrimEnd('\')

# `-c` config overrides work on both `resume` and a fresh session, unlike `-m`
# which `resume` doesn't accept - use `-c model=` uniformly for both paths.
$extraArgs = @()
if ($Model)  { $extraArgs += @("-c", "model=$Model") }
if ($Effort) { $extraArgs += @("-c", "model_reasoning_effort=$Effort") }

# GPT-backed Codex models are launched in YOLO mode. Keep other providers on
# their normal approval/sandbox settings.
if ($Model -match '^gpt') { $extraArgs += "--dangerously-bypass-approvals-and-sandbox" }

# Stock window is 272k; MAX only pays off on models whose max_context_window is 872k.
switch ($ContextWindow) {
    "0.25m" { $extraArgs += @("-c", "model_context_window=250000") }
    "0.5m"  { $extraArgs += @("-c", "model_context_window=500000") }
    "MAX"   { $extraArgs += @("-c", "model_context_window=872000") }
}

Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray

# `--last` exits non-zero when this repo has no saved interactive session.
# Start a new one then; the next launch resumes it automatically.
& codex resume --last -C $cwd @extraArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[DevLayout] no saved Codex session for this repo; starting one." -ForegroundColor DarkGray
    & codex -C $cwd @extraArgs
}

exit $LASTEXITCODE
