# Per-tab launcher for pi. Used by the Pi layout variants.
# Sessions are stored per working directory, so `pi --continue` reopens the
# most recent conversation for that repo (same idea as `codex resume --last`).
#
# Model: openrouter/tencent/hy4-preview with contextWindow capped at 256k via
# ~/.pi/agent/models.json modelOverrides (ensured on each launch).

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum
)

$ModelId = "tencent/hy4-preview"
$ModelArg = "openrouter/$ModelId"
$ContextWindow = 256000

function Ensure-PiHy4ContextLimit {
    $agentDir = Join-Path $env:USERPROFILE ".pi\agent"
    if (-not (Test-Path $agentDir)) {
        New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    }

    $path = Join-Path $agentDir "models.json"
    $root = $null
    if (Test-Path $path) {
        try {
            $root = Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "[DevLayout] could not parse $path; leaving it alone."
            return
        }
    }
    if (-not $root) { $root = @{} }
    if (-not $root.providers) { $root.providers = @{} }
    if (-not $root.providers.openrouter) { $root.providers.openrouter = @{} }
    if (-not $root.providers.openrouter.modelOverrides) {
        $root.providers.openrouter.modelOverrides = @{}
    }

    $overrides = $root.providers.openrouter.modelOverrides
    $current = $overrides[$ModelId]
    if ($current -is [hashtable] -and $current.contextWindow -eq $ContextWindow) {
        return
    }

    if (-not ($current -is [hashtable])) { $current = @{} }
    $current.contextWindow = $ContextWindow
    $overrides[$ModelId] = $current

    $json = $root | ConvertTo-Json -Depth 20
    Set-Content -Path $path -Value $json -Encoding utf8
    Write-Host "[DevLayout] set $ModelId contextWindow=$ContextWindow in models.json" -ForegroundColor DarkGray
}

$cwd = (Get-Location).Path.TrimEnd('\')

Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray
Write-Host "[DevLayout] model: $ModelArg (context ${ContextWindow})" -ForegroundColor DarkGray

Ensure-PiHy4ContextLimit

& pi --continue --model $ModelArg
exit $LASTEXITCODE
