# Per-tab launcher for pi. Used by the Pi layout variants.
# Sessions are stored per working directory, so `pi --continue` reopens the
# most recent conversation for that repo (same idea as `codex resume --last`).
#
# Model/Effort/ContextWindow all come from the layout JSON:
#   model         -> --model <pattern>, e.g. "gpt-5.6-luna" or "openrouter/tencent/hy4-preview"
#   effort        -> --thinking <level> (off|minimal|low|medium|high|xhigh|max)
#   contextWindow -> modelOverrides.contextWindow in a per-tab config directory,
#                    because pi has no CLI flag for the context window and reads
#                    models.json only from its config directory.
#
# Why the per-tab config directory: modelOverrides live in <config dir>/models.json,
# and that file is global. Writing it from every tab makes the last tab launched win
# for all of them. pi resolves its whole config directory from PI_CODING_AGENT_DIR,
# so each tab gets an overlay directory under ~/.pi/devlayout/w<N>-t<M> that holds
# its own models.json and shares every other entry of ~/.pi/agent through NTFS
# junctions (subdirectories) and hard links (files): AGENTS.md, SYSTEM.md, skills,
# MCP config and extension settings included. pi writes those shared files in place,
# never through a temp-file rename, so a hard link keeps both names on the same data.
# The overlay's models.json is the global one (custom providers and all) with this
# tab's contextWindow override merged in.
#
# The sessions directory is one of the junctioned subdirectories. pi stores a session
# in <config dir>\sessions\--<cwd with separators replaced>--, so junctioning
# <overlay>\sessions onto ~/.pi/agent/sessions keeps every tab on the one global
# store while pi keeps its per-working-directory split, which is what `pi --continue`
# resumes from. Do not set PI_CODING_AGENT_SESSION_DIR instead: that variable names
# the exact session directory, so pi drops the per-working-directory split and every
# tab resumes whatever session was written last, in any repo.
#
# Tabs left on contextWindow "default" run pi untouched, with no overlay at all.

#Requires -Version 5.1

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
$overlayRoot = Join-Path $env:USERPROFILE ".pi\devlayout"

# Every entry of the global config directory is shared with the overlay except
# models.json, which the overlay rebuilds with its own override. Directories are
# junctioned, files hard linked.
$OverlayOwnedFiles = @("models.json")
# Shared subdirectories pi creates on demand. Create them in the global directory
# first so the junction has a target, otherwise the tab writes into the overlay,
# which is rebuilt on the next launch.
$SeededAgentDirs = @("sessions")
# Shared files pi creates on demand. Seed them in the global directory first so the
# hard link exists before pi writes, otherwise the write lands in the overlay only.
$SeededAgentFiles = @{ "trust.json" = "{}" }
# pi's thinking levels, accepted as a ":<level>" suffix on --model.
$ThinkingLevels = @("off", "minimal", "low", "medium", "high", "xhigh", "max")

function Get-PiModelInfo {
    <#
        Resolve a layout `model` value to the provider key and bare model id that
        models.json wants for modelOverrides. Accepts both the bare id
        ("gpt-5.6-luna") and the provider-qualified form pi's --model also takes
        ("openrouter/tencent/hy4-preview").
    #>
    param([string]$Pattern)

    $info = @{ Provider = $null; ModelId = $Pattern; ContextWindow = $null }
    if (-not $Pattern) { return $info }

    # Strip pi's optional ":<thinking>" suffix before matching against the catalog.
    # Only a known level counts: ids such as "...:free" or "...:batch" contain a
    # colon of their own.
    $bare = $Pattern
    $colon = $Pattern.LastIndexOf(':')
    if ($colon -gt 0 -and $ThinkingLevels -contains $Pattern.Substring($colon + 1).ToLowerInvariant()) {
        $bare = $Pattern.Substring(0, $colon)
    }

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
        Note that for the OpenAI GPT-5.6 models the catalog window is pi's
        short-context-pricing default (272000), not the provider ceiling, so "MAX"
        is a no-op there and "1m" is what opts into the long-context window.
    #>
    param([string]$Token, $ModelMax)

    switch -Regex ($Token) {
        '^$'            { return $null }
        '^(?i)default$' { return $null }
        '^(?i)0\.25m$'  { return 256000 }
        '^(?i)0\.5m$'   { return 512000 }
        '^(?i)1m$'      { return 1000000 }
        '^(?i)max$'     { if ($ModelMax) { return [int]$ModelMax } else { return $null } }
        '^\d+$'         { return [int]$Token }
    }
    Write-Warning "[DevLayout] unknown contextWindow '$Token'; leaving the context window alone."
    return $null
}

function Remove-PiAgentOverlay {
    <#
        Tear down an overlay directory. Junctions are removed as reparse points
        first: Remove-Item -Recurse on a junction can delete the target's contents
        on Windows PowerShell 5.1, and the target here is the real config directory.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    foreach ($entry in (Get-ChildItem -LiteralPath $Path -Force -Directory -ErrorAction SilentlyContinue)) {
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            try { [System.IO.Directory]::Delete($entry.FullName, $false) } catch { }
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-PiAgentOverlay {
    <#
        Build the per-tab config directory and return its path, or $null when the
        overlay could not be built. The overlay is rebuilt on every launch so the
        hard links always point at the current global files.
    #>
    param(
        [string]$Slot,
        [string]$Provider,
        [string]$ModelId,
        [int]$Tokens
    )

    if (-not (Test-Path -LiteralPath $agentDir)) {
        Write-Warning "[DevLayout] $agentDir does not exist; running pi with its own config."
        return $null
    }

    $path = Join-Path $overlayRoot $Slot

    try {
        Remove-PiAgentOverlay -Path $path
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        foreach ($name in $SeededAgentDirs) {
            $target = Join-Path $agentDir $name
            if (-not (Test-Path -LiteralPath $target)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
            }
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        foreach ($name in $SeededAgentFiles.Keys) {
            $target = Join-Path $agentDir $name
            if (-not (Test-Path -LiteralPath $target)) {
                [System.IO.File]::WriteAllText($target, $SeededAgentFiles[$name], $utf8NoBom)
            }
        }

        foreach ($entry in (Get-ChildItem -LiteralPath $agentDir -Force)) {
            if ($OverlayOwnedFiles -contains $entry.Name) { continue }
            $link = Join-Path $path $entry.Name
            if ($entry.PSIsContainer) {
                New-Item -ItemType Junction -Path $link -Target $entry.FullName -ErrorAction Stop | Out-Null
            } else {
                New-Item -ItemType HardLink -Path $link -Target $entry.FullName -ErrorAction Stop | Out-Null
            }
        }

        # Start from the global models.json so custom providers and the user's own
        # overrides still apply, then set this tab's context window on top.
        $root = $null
        $globalModels = Join-Path $agentDir "models.json"
        if (Test-Path -LiteralPath $globalModels) {
            $root = Get-Content -LiteralPath $globalModels -Raw -Encoding utf8 | ConvertFrom-Json
        }
        if ($null -eq $root) { $root = New-Object PSObject }
        $node = $root
        foreach ($key in @("providers", $Provider, "modelOverrides", $ModelId)) {
            if ($null -eq $node.PSObject.Properties[$key]) {
                $node | Add-Member -MemberType NoteProperty -Name $key -Value (New-Object PSObject)
            }
            $node = $node.$key
        }
        $node | Add-Member -MemberType NoteProperty -Name contextWindow -Value $Tokens -Force

        $json = $root | ConvertTo-Json -Depth 20
        # Set-Content -Encoding utf8 writes a BOM on 5.1; write the bytes directly.
        [System.IO.File]::WriteAllText((Join-Path $path "models.json"), $json, $utf8NoBom)
    } catch {
        Write-Warning "[DevLayout] could not build the pi config overlay at ${path}: $($_.Exception.Message)"
        Remove-PiAgentOverlay -Path $path
        return $null
    }

    return $path
}

$cwd = (Get-Location).Path.TrimEnd('\')

$modelPattern = if ($Model) { $Model } else { $DefaultModel }
$info = Get-PiModelInfo -Pattern $modelPattern
$window = Resolve-PiContextWindow -Token $ContextWindow -ModelMax $info.ContextWindow

# An override equal to the catalog window changes nothing, so skip the overlay and
# leave the tab on pi's own configuration.
if ($window -and $info.ContextWindow -and [int]$info.ContextWindow -eq [int]$window) {
    $window = $null
}

$piArgs = @("--continue", "--model", $modelPattern)
if ($Effort) { $piArgs += @("--thinking", $Effort) }

$ctxNote = if ($window) { "context $window" } else { "context default" }
Write-Host "[DevLayout] $Label" -ForegroundColor Cyan
Write-Host "[DevLayout] repo: $cwd" -ForegroundColor DarkGray
Write-Host "[DevLayout] model: $modelPattern (thinking ${Effort}, $ctxNote)" -ForegroundColor DarkGray

if ($window) {
    if (-not $info.Provider) {
        Write-Warning "[DevLayout] no provider known for model '$modelPattern'; leaving the context window alone."
    } else {
        $slotWindow = if ($WindowNum) { $WindowNum } else { "0" }
        $slotTab = if ($TabIndex) { $TabIndex } else { "0" }
        $overlay = New-PiAgentOverlay -Slot "w$slotWindow-t$slotTab" -Provider $info.Provider -ModelId $info.ModelId -Tokens $window
        if ($overlay) {
            $env:PI_CODING_AGENT_DIR = $overlay
            Write-Host "[DevLayout] set $($info.Provider)/$($info.ModelId) contextWindow=$window via $overlay" -ForegroundColor DarkGray
        }
    }
}

& pi @piArgs
exit $LASTEXITCODE
