#Requires -Version 5.1
# Regression test for ps1-scripts\Install-Skills.ps1. Uses temp directories only.

$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $toolkitDir "ps1-scripts\Install-Skills.ps1"
$failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "PASS  $Message" } else { Write-Host "FAIL  $Message"; $script:failures++ }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("skills-test-" + [guid]::NewGuid().ToString("N"))
$claude = Join-Path $root "claude"
New-Item -ItemType Directory -Path $claude -Force | Out-Null

try {
    $skillDir = Join-Path $claude "skills\memory-lint"
    $skillFile = Join-Path $skillDir "SKILL.md"
    $script = Join-Path $skillDir "memory_lint.py"

    & $installer -ClaudeDir (Join-Path $root "missing") *> $null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "missing"))) "missing Claude directory is skipped"

    & $installer -ClaudeDir $claude -WhatIf *> $null
    Assert-True (-not (Test-Path -LiteralPath $skillDir)) "-WhatIf writes nothing"

    & $installer -ClaudeDir $claude *> $null
    Assert-True ((Test-Path -LiteralPath $skillFile) -and (Test-Path -LiteralPath $script)) "skill files are installed"
    Assert-True (-not [System.IO.File]::ReadAllText($skillFile).Contains("`r")) "installed files use LF"

    $stamp = (Get-Item -LiteralPath $skillFile).LastWriteTimeUtc
    & $installer -ClaudeDir $claude *> $null
    Assert-True ((Get-Item -LiteralPath $skillFile).LastWriteTimeUtc -eq $stamp) "second run changes nothing"

    [System.IO.File]::WriteAllText($skillFile, "edited by the user`n")
    $threw = $false
    try { & $installer -ClaudeDir $claude *> $null } catch { $threw = $true }
    Assert-True ($threw -and [System.IO.File]::ReadAllText($skillFile) -ceq "edited by the user`n") "a differing file stops the run"

    & $installer -ClaudeDir $claude -Force *> $null
    Assert-True ([System.IO.File]::ReadAllText($skillFile).Contains("name: memory-lint")) "-Force replaces it"

    $own = Join-Path $skillDir "notes.txt"
    [System.IO.File]::WriteAllText($own, "mine")
    & $installer -ClaudeDir $claude -Remove *> $null
    Assert-True ((Test-Path -LiteralPath $own) -and -not (Test-Path -LiteralPath $skillFile)) "-Remove keeps a file the toolkit does not ship"

    Remove-Item -LiteralPath $own -Force
    & $installer -ClaudeDir $claude *> $null
    & $installer -ClaudeDir $claude -Remove *> $null
    Assert-True (-not (Test-Path -LiteralPath $skillDir)) "-Remove deletes the folder when it is empty"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host "All skill installer tests passed"
