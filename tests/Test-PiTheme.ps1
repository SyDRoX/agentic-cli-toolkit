#Requires -Version 5.1
# Standalone regression test; no Pester or installed Pi required.
$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $toolkitDir "ps1-scripts\Install-PiTheme.ps1"
$source = Join-Path $toolkitDir "themes\pi\sydrox-orange-matrix.json"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pi-theme-test-" + [guid]::NewGuid())
$agentDir = Join-Path $tempRoot "agent [isolated]"
$destination = Join-Path $agentDir "themes\sydrox-orange-matrix.json"

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected error matching: $Pattern"
}
function Get-Hash([string]$Path) {
    # A byte signature without optional PowerShell module dependencies.
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

try {
    $theme = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($theme.name -eq "sydrox-orange-matrix") "Theme name mismatch"
    Assert-True ($null -ne $theme.colors.accent) "Theme colors missing"

    & $installer -AgentDir $agentDir -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $agentDir)) "WhatIf created directories"

    & $installer -AgentDir $agentDir
    Assert-True ((Get-Hash $source) -eq (Get-Hash $destination)) "Install changed theme bytes"

    # Repeat installation must be a true no-op.
    $timestamp = (Get-Item -LiteralPath $destination).LastWriteTimeUtc
    & $installer -AgentDir $agentDir
    Assert-True ((Get-Item -LiteralPath $destination).LastWriteTimeUtc -eq $timestamp) "Repeat install rewrote theme"

    $settings = Join-Path $agentDir "settings.json"
    $otherTheme = Join-Path $agentDir "themes\other.json"
    [IO.File]::WriteAllText($settings, '{"theme":"other","custom":true}')
    [IO.File]::WriteAllText($otherTheme, '{"name":"other"}')
    $settingsHash = Get-Hash $settings
    $otherHash = Get-Hash $otherTheme
    [IO.File]::WriteAllText($destination, '{"name":"customized"}')
    $customHash = Get-Hash $destination

    Assert-Throws { & $installer -AgentDir $agentDir } "*Use -Force*"
    Assert-True ((Get-Hash $destination) -eq $customHash) "Conflict changed theme"

    & $installer -AgentDir $agentDir -Force -WhatIf
    Assert-True ((Get-Hash $destination) -eq $customHash) "WhatIf replaced theme"
    & $installer -AgentDir $agentDir -Force
    Assert-True ((Get-Hash $source) -eq (Get-Hash $destination)) "Force failed"
    Assert-True ((Get-Hash $settings) -eq $settingsHash) "Installer changed settings"
    Assert-True ((Get-Hash $otherTheme) -eq $otherHash) "Installer changed unrelated theme"

    Remove-Item -LiteralPath $destination
    New-Item -ItemType Directory -Path $destination | Out-Null
    Assert-Throws { & $installer -AgentDir $agentDir -Force } "*not a file*"

    Push-Location -LiteralPath $tempRoot
    try {
        & $installer -AgentDir ".\relative"
        & $installer -AgentDir ".\relative"
        $relativeTheme = Join-Path $tempRoot "relative\themes\sydrox-orange-matrix.json"
        Assert-True ((Get-Hash $relativeTheme) -eq (Get-Hash $source)) "Relative installation failed"
    } finally {
        Pop-Location
    }

    Write-Host "PASS: Pi theme JSON, install, repeat, WhatIf, conflict, Force, preservation, directory rejection, relative paths"
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
