#Requires -Version 5.1
# Regression test for ps1-scripts\Install-AgentRules.ps1. Uses temp directories only.

$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $toolkitDir "ps1-scripts\Install-AgentRules.ps1"
$failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { Write-Host "PASS  $Message" } else { Write-Host "FAIL  $Message"; $script:failures++ }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-rules-test-" + [guid]::NewGuid().ToString("N"))
$claude = Join-Path $root "claude"
$codex = Join-Path $root "codex"
$pi = Join-Path $root "pi-missing"
New-Item -ItemType Directory -Path $claude, $codex -Force | Out-Null

try {
    $claudeFile = Join-Path $claude "CLAUDE.md"
    $codexFile = Join-Path $codex "AGENTS.md"
    [System.IO.File]::WriteAllText($claudeFile, "# Mine`r`n`r`nKeep this line.`r`n")

    & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi -WhatIf *> $null
    Assert-True (-not (Test-Path -LiteralPath $codexFile)) "-WhatIf writes nothing"

    & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi *> $null
    $claudeText = [System.IO.File]::ReadAllText($claudeFile)
    $codexText = [System.IO.File]::ReadAllText($codexFile)
    Assert-True ($claudeText.StartsWith("# Mine`r`n`r`nKeep this line.`r`n")) "existing Claude text is kept"
    Assert-True ($claudeText.Contains("## Tests and evidence")) "rules are appended to CLAUDE.md"
    Assert-True (-not ($claudeText -replace "`r`n", "").Contains("`n")) "CRLF file gets a CRLF block"
    Assert-True ($codexText.Contains("## Tests and evidence") -and -not $codexText.Contains("`r")) "new Codex AGENTS.md is created with LF"
    Assert-True (-not (Test-Path -LiteralPath $pi)) "missing pi directory is skipped"

    & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi *> $null
    Assert-True ([System.IO.File]::ReadAllText($claudeFile) -ceq $claudeText) "second run changes nothing"

    $stale = $claudeText -replace "## Tests and evidence", "## Old heading"
    [System.IO.File]::WriteAllText($claudeFile, $stale + "`r`nTrailing text.`r`n")
    & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi *> $null
    $repaired = [System.IO.File]::ReadAllText($claudeFile)
    Assert-True ($repaired.Contains("## Tests and evidence") -and -not $repaired.Contains("## Old heading")) "changed block is replaced"
    Assert-True ($repaired.Contains("Trailing text.") -and ([regex]::Matches($repaired, ">>> agentic-cli-toolkit working rules").Count -eq 1)) "text after the block is kept, one block only"

    & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi -Remove *> $null
    $removed = [System.IO.File]::ReadAllText($claudeFile)
    Assert-True ($removed.Contains("Keep this line.") -and $removed.Contains("Trailing text.") -and -not $removed.Contains("working rules")) "-Remove takes only the block out"

    [System.IO.File]::WriteAllText($claudeFile, "<!-- <<< agentic-cli-toolkit working rules -->`n")
    $threw = $false
    try { & $installer -ClaudeDir $claude -CodexDir $codex -PiDir $pi *> $null } catch { $threw = $true }
    Assert-True $threw "unbalanced markers stop the run"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host "All agent rules tests passed"
