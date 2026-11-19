#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the bundled working rules for Claude Code, Codex and pi.
.DESCRIPTION
    Writes rules\agent-rules.md as a managed block into each agent's global
    instruction file: <ClaudeDir>\CLAUDE.md, <CodexDir>\AGENTS.md and
    <PiDir>\AGENTS.md. Text outside the block is never changed, and a second run
    replaces the block in place. An agent whose directory does not exist is skipped.
    Use -WhatIf to preview and -Remove to take the block out again.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [ValidateNotNullOrEmpty()]
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [ValidateNotNullOrEmpty()]
    [string]$PiDir = (Join-Path $env:USERPROFILE ".pi\agent"),
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$source = Join-Path $toolkitDir "rules\agent-rules.md"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$blockStart = "<!-- >>> agentic-cli-toolkit working rules (Install-AgentRules.ps1); edit rules\agent-rules.md, not this block -->"
$blockEnd = "<!-- <<< agentic-cli-toolkit working rules -->"

$rules = [System.IO.File]::ReadAllText($source).Replace("`r`n", "`n").Trim()
if (-not $rules) { throw "Bundled rules file is empty: $source" }

function Set-RulesBlock {
    <# Return the file text with the managed block replaced, appended or removed. #>
    param([string]$Text, [string]$Block, [string]$Path)

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $start = $Text.IndexOf($blockStart)
    $end = $Text.IndexOf($blockEnd)
    if (($start -ge 0) -ne ($end -ge 0) -or ($end -ge 0 -and $end -lt $start)) {
        throw "Unbalanced working rules markers in $Path. Fix or remove them by hand."
    }

    $before = $Text
    $after = ""
    if ($start -ge 0) {
        $before = $Text.Substring(0, $start)
        $after = $Text.Substring($end + $blockEnd.Length)
    }
    $before = $before.TrimEnd()
    $after = $after.Trim()

    $parts = @()
    if ($before) { $parts += $before }
    if ($Block) { $parts += $Block.Replace("`n", $newline) }
    if ($after) { $parts += $after }
    if ($parts.Count -eq 0) { return "" }
    return ($parts -join ($newline + $newline)) + $newline
}

$targets = @(
    @{ Agent = "Claude"; Dir = $ClaudeDir; File = "CLAUDE.md" },
    @{ Agent = "Codex"; Dir = $CodexDir; File = "AGENTS.md" },
    @{ Agent = "pi"; Dir = $PiDir; File = "AGENTS.md" }
)
$block = if ($Remove) { "" } else { "$blockStart`n$rules`n$blockEnd" }

foreach ($target in $targets) {
    # Resolve relative paths against PowerShell location, not the .NET process cwd.
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($target.Dir)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Host "$($target.Agent): $dir not found, skipped."
        continue
    }

    $path = Join-Path $dir $target.File
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $current = if ($exists) { [System.IO.File]::ReadAllText($path) } else { "" }
    $updated = Set-RulesBlock -Text $current -Block $block -Path $path

    if ($updated -ceq $current) {
        Write-Host "$($target.Agent): already up to date: $path"
        continue
    }
    if (-not $exists -and -not $updated) { continue }

    if ($target.Agent -eq "pi" -and (Test-Path -LiteralPath (Join-Path $dir "AGENTS.override.md"))) {
        Write-Warning "pi: AGENTS.override.md in $dir replaces AGENTS.md, so pi will not read the rules."
    }

    $action = if ($Remove) { "Remove working rules block" } else { "Write working rules block" }
    if ($PSCmdlet.ShouldProcess($path, $action)) {
        [System.IO.File]::WriteAllText($path, $updated, $utf8NoBom)
        Write-Host "$($target.Agent): $($action.ToLowerInvariant()): $path"
    }
}

if (-not $WhatIfPreference -and -not $Remove) {
    Write-Host "New sessions read the rules. Edit rules\agent-rules.md and run this script again to change them."
}
