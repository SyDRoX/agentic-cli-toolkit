#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the bundled Pi theme without changing Pi settings.
.DESCRIPTION
    Copies the theme into the global Pi agent directory by default. Use
    -AgentDir for an alternate installation, -WhatIf to preview, and -Force
    to replace a differing theme. Select sydrox-orange-matrix in Pi /settings.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$AgentDir = (Join-Path $env:USERPROFILE ".pi\agent"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
# Resolve relative paths against PowerShell location, not the .NET process cwd.
$AgentDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AgentDir)
$toolkitDir = Split-Path -Parent $PSScriptRoot
$themeName = "sydrox-orange-matrix"
$source = Join-Path $toolkitDir "themes\pi\$themeName.json"
$theme = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
if ($theme.name -ne $themeName -or $null -eq $theme.colors) {
    throw "Invalid bundled Pi theme: $source"
}

$themesDir = Join-Path $AgentDir "themes"
$destination = Join-Path $themesDir "$themeName.json"
if (Test-Path -LiteralPath $destination) {
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw "Theme destination is not a file: $destination"
    }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($source)) -eq
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination))) {
        Write-Host "Pi theme already up to date: $destination"
        return
    }
    if (-not $Force) {
        throw "Theme differs: $destination. Use -Force to replace it."
    }
}

if ($PSCmdlet.ShouldProcess($destination, "Install bundled Pi theme")) {
    if (-not (Test-Path -LiteralPath $themesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $themesDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Host "Pi theme installed: $destination"
    Write-Host "Select $themeName in Pi /settings (run /reload if already open)."
}
