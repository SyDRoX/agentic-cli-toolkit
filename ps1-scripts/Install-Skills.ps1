#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the bundled Claude Code skills.
.DESCRIPTION
    Copies each folder under skills\ into <ClaudeDir>\skills\<name>. A destination
    file that differs is left alone unless -Force is given. -Remove deletes only the
    files this toolkit ships, and a skill folder only when that leaves it empty.
    Use -WhatIf to preview.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [switch]$Force,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $toolkitDir "skills"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Resolve relative paths against PowerShell location, not the .NET process cwd.
$claudeRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClaudeDir)
if (-not (Test-Path -LiteralPath $claudeRoot -PathType Container)) {
    Write-Host "Claude: $claudeRoot not found, skipped."
    return
}

$files = @()
$skillNames = @()
foreach ($skill in (Get-ChildItem -LiteralPath $sourceRoot -Directory | Sort-Object Name)) {
    if (-not (Test-Path -LiteralPath (Join-Path $skill.FullName "SKILL.md") -PathType Leaf)) {
        throw "Bundled skill has no SKILL.md: $($skill.FullName)"
    }
    $skillNames += $skill.Name
    foreach ($file in (Get-ChildItem -LiteralPath $skill.FullName -File | Sort-Object Name)) {
        $files += @{
            Skill = $skill.Name
            Destination = (Join-Path (Join-Path (Join-Path $claudeRoot "skills") $skill.Name) $file.Name)
            Content = [System.IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
        }
    }
}
if ($files.Count -eq 0) { throw "No bundled skills found in $sourceRoot" }

if ($Remove) {
    foreach ($file in $files) {
        if ((Test-Path -LiteralPath $file.Destination -PathType Leaf) -and $PSCmdlet.ShouldProcess($file.Destination, "Remove skill file")) {
            Remove-Item -LiteralPath $file.Destination -Force
            Write-Host "Removed: $($file.Destination)"
        }
    }
    foreach ($name in $skillNames) {
        $dir = Join-Path (Join-Path $claudeRoot "skills") $name
        if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
            if ($PSCmdlet.ShouldProcess($dir, "Remove empty skill folder")) { Remove-Item -LiteralPath $dir -Force }
        }
    }

    return
}

# Check every file first, so a differing destination stops the run before any write.
$pending = @()
foreach ($file in $files) {
    if (Test-Path -LiteralPath $file.Destination) {
        if (-not (Test-Path -LiteralPath $file.Destination -PathType Leaf)) {
            throw "Destination is not a file: $($file.Destination)"
        }
        if ([System.IO.File]::ReadAllText($file.Destination) -ceq $file.Content) { continue }
        if (-not $Force) { throw "File differs: $($file.Destination). Use -Force to replace it." }
    }
    $pending += $file
}

if ($pending.Count -eq 0) {
    Write-Host "Skills already up to date."
    return
}

foreach ($file in $pending) {
    if ($PSCmdlet.ShouldProcess($file.Destination, "Install skill file")) {
        $parent = Split-Path -Parent $file.Destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($file.Destination, $file.Content, $utf8NoBom)
        Write-Host "Installed: $($file.Destination)"
    }
}

if (-not $WhatIfPreference) {
    Write-Host "Skills: $(($skillNames | ForEach-Object { '/' + $_ }) -join ', '). Restart Claude Code to load them."
}
