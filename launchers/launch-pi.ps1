# Per-tab launcher for pi. Used by the Pi layout variants.
# Sessions are stored per working directory, so `pi --continue` reopens the
# most recent conversation for that repo (same idea as `codex resume --last`).
#
# Model/Effort/ContextWindow all come from the layout JSON:
#   model         -> --model <pattern>, e.g. "gpt-5.6-luna" or "openrouter/tencent/hy4-preview"
#   effort        -> --thinking <level> (off|minimal|low|medium|high|xhigh|max)
#   contextWindow -> modelOverrides.contextWindow in ~/.pi/agent/models.json,
#                    because pi has no CLI flag for the context window.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TabIndex,
    [Parameter(Position = 1)][string]$Label,
    [Parameter(Position = 2)][string]$WindowNum,
    [Parameter(Position = 3)][string]$Model,
    [Parameter(Position = 4)][string]$Effort,
    [Parameter(Position = 5)][string]$ContextWindow
)

$DefaultModel = "gpt-5.6-luna"

$agentDir = Join-Path $env:USERPROFILE ".pi\agent"
$storePath = Join-Path $agentDir "models-store.json"

function Get-PiModelInfo {
    <#
        Resolve a layout `model` value to the provider key and bare model id that
        ~/.pi/agent/models.json wants for modelOverrides. Accepts both the bare id
        ("gpt-5.6-luna") and the provider-qualified form pi's --model also takes
        ("openrouter/tencent/hy4-preview").
    #>
    param([string]$Pattern)

    $info = @{ Provider = $null; ModelId = $Pattern; ContextWindow = $null }
    if (-not $Pattern) { return $info }

    # Strip pi's optional ":<thinking>" suffix before matching against the catalog.
    $bare = ($Pattern -split ':', 2)[0]

    if (-not (Test-Path $storePath)) {
        # No catalog cached: fall back to the "provider/id" split when present.
        if ($bare -match '^([^/]+)/(.+)$') {
            $info.Provider = $Matches[1]
            $info.ModelId = $Matches[2]
        } else {
            $info.ModelId = $bare
        }
        return $info
    }

    try {
        $store = Get-Content $storePath -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        Write-Warning "[DevLayout] could not parse $storePath; skipping context-window override."
        $info.ModelId = $bare
        return $info
    }

    # A provider-qualified pattern pins the provider; otherwise search every provider.
    $wantProvider = $null
    $wantId = $bare
    if ($bare -match '^([^/]+)/(.+)$' -and $store.PSObject.Properties.Name -contains $Matches[1]) {
        $wantProvider = $Matches[1]
        $wantId = $Matches[2]
    }

    foreach ($prop in $store.PSObject.Properties) {
        if ($wantProvider -and $prop.Name -ne $wantProvider) { continue }
        foreach ($m in $prop.Value.models) {
            if ($m.id -eq $wantId) {
                $info.Provider = $prop.Name
                $info.ModelId = $m.id
                $info.ContextWindow = $m.contextWindow
                return $info
            }
        }
    }

    $info.Provider = $wantProvider
    $info.ModelId = $wantId
    return $info
}

function Resolve-PiContextWindow {
    <#
        Translate the layout's contextWindow token into a token count. "MAX" means
        the model's own stock window from the catalog; a raw integer passes through.
    #>
    param([string]$Token, $ModelMax)

    switch -Regex ($Token) {
        '^$'          { return $null }
        '^(?i)default$' { return $null }
        '^(?i)0\.25m$'  { return 256000 }
        '^(?i)0\.5m$'   { return 512000 }
        '^(?i)1m$'      { return 1000000 }
        '^(?i)max$'     { if ($ModelMax) { return [int]$ModelMax } else { return $null } }
        '^\d+$'         { return [int]$Token }
    }
    Write-Warning "[DevLayout] unknown contextWindow '$Token'; leaving models.json alone."
    return $null
}

function Set-PiContextWindow {
    <#
        pi reads per-model overrides from ~/.pi/agent/models.json. Rewrite only the
        one model's contextWindow and leave every other key in that file untouched.
    #>
    param([string]$Provider, [string]$ModelId, [int]$Window)

    if (-not $Provider -or -not $ModelId -or -not $Window) { return }

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
    if (-not $root.providers[$Provider]) { $root.providers[$Provider] = @{} }
    if (-not $root.providers[$Provider].modelOverrides) {
        $root.providers[$Provider].modelOverrides = @{}
    }

    $overrides = $root.providers[$Provider].modelOverrides
    $current = $overrides[$ModelId]
    if ($current -is [hashtable] -and $current.contextWindow -eq $Window) {
        return
    }

    if (-not ($current -is [hashtable])) { $current = @{} }
    $current.contextWindow = $Window
    $overrides[$ModelId] = $current

    $json = $root | ConvertTo-Json -Depth 20
    Set-Content -Path $path -Value $json -Encoding utf8
    Write-Host "[DevLayout] set $Provider/$ModelId contextWindow=$Window in models.json" -ForegroundColor DarkGray
}

$cwd = (Get-Location).Path.TrimEnd('\')

$modelPattern = if ($Model) { $Model } else { $DefaultModel }
$info = Get-PiModelInfo -Pattern $modelPattern
$window = Resolve-PiContextWindow -Token $ContextWindow -ModelMax $info.ContextWindow

$piArgs = @("--continue", "--model", $modelPattern)
if ($Effort) { $piArgs += @("--thinking", $Effort) }

$ctxNote = if ($window) { "context $window" } else { "context default" }
Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray
Write-Host "[DevLayout] model: $modelPattern (thinking ${Effort}, $ctxNote)" -ForegroundColor DarkGray

if ($window) {
    Set-PiContextWindow -Provider $info.Provider -ModelId $info.ModelId -Window $window
}

& pi @piArgs
exit $LASTEXITCODE
