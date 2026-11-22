#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the bundled response styles for Claude Code, Codex and pi.
.DESCRIPTION
    Writes one output style per bundled style into <ClaudeDir>\output-styles and the
    /style skill into <ClaudeDir>\skills\style. Use -ClaudeDir for an alternate
    installation, -WhatIf to preview, and -Force to replace a differing file.

    The catalog default ("default": true in styles.json) also applies outside the
    layout launchers: Codex gets it as a managed developer_instructions block at the
    top of <CodexDir>\config.toml, and pi gets a global extension shim in
    <PiDir>\extensions that loads the style extension from this checkout. Each part
    is skipped when that agent's directory does not exist. Claude settings are never
    edited; set the Claude default with /style.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [ValidateNotNullOrEmpty()]
    [string]$CodexDir = (Join-Path $env:USERPROFILE ".codex"),
    [ValidateNotNullOrEmpty()]
    [string]$PiDir = (Join-Path $env:USERPROFILE ".pi\agent"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
# Resolve relative paths against PowerShell location, not the .NET process cwd.
$ClaudeDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ClaudeDir)
$CodexDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CodexDir)
$PiDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PiDir)
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

if (Test-Path -LiteralPath $PiDir -PathType Container) {
    $files += @{ Destination = (Get-PiStyleShimPath -PiDir $PiDir); Content = (ConvertTo-PiStyleShim) }
}

# The managed block is ours to rewrite, so a changed block needs no -Force.
$codexConfig = Join-Path $CodexDir "config.toml"
$codexText = $null
if (Test-Path -LiteralPath $CodexDir -PathType Container) {
    $defaultKey = Get-DefaultResponseStyleKey
    $defaultStyle = if ($defaultKey) { Resolve-ResponseStyle -Name $defaultKey } else { $null }
    $currentText = if (Test-Path -LiteralPath $codexConfig) { [System.IO.File]::ReadAllText($codexConfig) } else { "" }
    $newText = Set-CodexStyleBlock -ConfigText $currentText -Style $defaultStyle
    if ($newText -cne $currentText.Replace("`r`n", "`n")) { $codexText = $newText }
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

if ($pending.Count -eq 0 -and $null -eq $codexText) {
    Write-Host "Response styles already up to date."
    return
}

if ($null -ne $codexText -and $PSCmdlet.ShouldProcess($codexConfig, "Set the default response style block")) {
    [System.IO.File]::WriteAllText($codexConfig, $codexText, $utf8NoBom)
    Write-Host "Updated: $codexConfig"
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
    Write-Host "Default style: $(Get-DefaultResponseStyleKey). Set the Claude default with /style, or per tab with `"style`" in a layout preset."
}
