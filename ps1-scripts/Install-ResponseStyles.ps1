#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the bundled response styles for Claude Code without changing its settings.
.DESCRIPTION
    Writes one output style per bundled style into <ClaudeDir>\output-styles and the
    /style skill into <ClaudeDir>\skills\style. Use -ClaudeDir for an alternate
    installation, -WhatIf to preview, and -Force to replace a differing file.
    Codex and pi need no installation: their launchers read the styles from this
    checkout.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
# Resolve relative paths against PowerShell location, not the .NET process cwd.
$ClaudeDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClaudeDir)
$toolkitDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "ResponseStyle.ps1")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$skillSource = Join-Path $toolkitDir "styles\claude-skill"
$skillDir = Join-Path $ClaudeDir "skills\style"
$outputStylesDir = Join-Path $ClaudeDir "output-styles"

$catalog = Get-ResponseStyleCatalog
if ($catalog.Count -eq 0) { throw "No bundled styles found in $(Join-Path $toolkitDir 'styles')" }

# Build every file first, so a differing destination stops the run before any write.
$files = @()
$skillCatalog = [ordered]@{}
foreach ($key in $catalog.Keys) {
    $style = Resolve-ResponseStyle -Name $key
    if (-not $style) { throw "Bundled style '$key' has no rules file." }
    $destination = Get-ClaudeOutputStylePath -Style $style -ClaudeDir $ClaudeDir
    $files += @{ Destination = $destination; Content = (ConvertTo-ClaudeOutputStyle -Style $style) }
    $skillCatalog[$key] = [ordered]@{ label = $style.Label; file = (Split-Path -Leaf $destination) }

    if (Test-Path -LiteralPath $outputStylesDir) {
        foreach ($other in (Get-ChildItem -LiteralPath $outputStylesDir -Filter *.md -File)) {
            if ($other.FullName -eq $destination) { continue }
            $head = Get-Content -LiteralPath $other.FullName -TotalCount 6 -Encoding UTF8
            if ($head -match ("^name:\s*" + [regex]::Escape($style.Label) + "\s*$")) {
                Write-Warning "Another output style is also named '$($style.Label)': $($other.FullName). Remove or rename it, or Claude may select either one."
            }
        }
    }
}
$files += @{ Destination = (Join-Path $skillDir "styles.json"); Content = (($skillCatalog | ConvertTo-Json -Depth 5).Replace("`r`n", "`n") + "`n") }
foreach ($name in @("SKILL.md", "Switch-ResponseStyle.ps1")) {
    $files += @{ Destination = (Join-Path $skillDir $name); Content = [System.IO.File]::ReadAllText((Join-Path $skillSource $name)).Replace("`r`n", "`n") }
}

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
    Write-Host "Response styles already up to date in $ClaudeDir"
    return
}

foreach ($file in $pending) {
    if ($PSCmdlet.ShouldProcess($file.Destination, "Install response style file")) {
        $parent = Split-Path -Parent $file.Destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($file.Destination, $file.Content, $utf8NoBom)
        Write-Host "Installed: $($file.Destination)"
    }
}

if (-not $WhatIfPreference) {
    $labels = ($catalog.Values | ForEach-Object { $_.Label }) -join ", "
    Write-Host "Output styles: $labels. Skill: /style. Restart Claude Code to load them."
    Write-Host "Set a default with /style, or per tab with `"style`" in a layout preset."
}
