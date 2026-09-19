#Requires -Version 5.1
<#
.SYNOPSIS
Install agentic-cli-notify into ~/.claude/hooks/agentic-cli-notify.

.DESCRIPTION
Copies the hook scripts, compiles save-hwnd.exe with the .NET Framework 4
compiler, and registers the notification hooks for every agent CLI found on
this machine (Codex, Cursor Agent, pi). Claude Code hooks are printed for
manual registration in settings.json.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#>
param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify')
)

$ErrorActionPreference = 'Stop'

$repoDir = $PSScriptRoot
$ps1Dir = Join-Path $repoDir 'ps1-scripts'

Write-Host "Installing agentic-cli-notify to $InstallDir"
$null = New-Item -ItemType Directory -Path $InstallDir -Force

$files = @(
    (Join-Path $ps1Dir 'notify.ps1'),
    (Join-Path $ps1Dir 'popup.ps1'),
    (Join-Path $ps1Dir 'codex-hook.ps1'),
    (Join-Path $ps1Dir 'cursor-hook.ps1'),
    (Join-Path $repoDir 'attention.cmd'),
    (Join-Path $repoDir 'resume.cmd'),
    (Join-Path $repoDir 'setup.ps1'),
    (Join-Path $repoDir 'SaveHwnd.cs')
)
foreach ($file in $files) {
    Copy-Item -LiteralPath $file -Destination $InstallDir -Force
}

# ---------------------------------------------------------------------------
# Compile save-hwnd.exe
# ---------------------------------------------------------------------------
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$wpf = Join-Path (Split-Path $compiler) 'WPF'
$exePath = Join-Path $InstallDir 'save-hwnd.exe'
$sourcePath = Join-Path $InstallDir 'SaveHwnd.cs'

if (Test-Path -LiteralPath $compiler) {
    Write-Host 'Compiling save-hwnd.exe...'
    & $compiler -nologo -optimize+ "-out:$exePath" $sourcePath `
        "-r:$wpf\UIAutomationClient.dll" "-r:$wpf\UIAutomationTypes.dll" '-r:System.Management.dll'
    if ($LASTEXITCODE -ne 0) { throw 'save-hwnd.exe compilation failed.' }
    Write-Host 'Compiled successfully.'
} else {
    Write-Warning ".NET Framework csc.exe not found at $compiler"
    $bundled = Join-Path $repoDir 'save-hwnd.exe'
    if (Test-Path -LiteralPath $bundled) {
        Write-Host 'Falling back to the bundled save-hwnd.exe.'
        Copy-Item -LiteralPath $bundled -Destination $InstallDir -Force
    } else {
        throw 'No save-hwnd.exe available. Compile manually or install .NET Framework 4.'
    }
}

# ---------------------------------------------------------------------------
# Register the agent CLIs present on this machine
# ---------------------------------------------------------------------------
# Claude Code hooks are registered further down via settings.json.
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if (Test-Path -LiteralPath $codexDir) {
    Write-Host 'Registering Codex hooks...'
    try {
        & (Join-Path $ps1Dir 'register-codex-hooks.ps1') -CodexDir $codexDir -NotifyDir $InstallDir
    } catch {
        Write-Warning "Codex hook registration failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.cursor')) {
    Write-Host 'Registering Cursor Agent hooks...'
    try {
        & (Join-Path $ps1Dir 'register-cursor-hooks.ps1') -NotifyDir $InstallDir
    } catch {
        Write-Warning "Cursor hook registration failed: $($_.Exception.Message)"
    }
}

if (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.pi\agent')) {
    Write-Host 'Installing pi extension...'
    try {
        & (Join-Path $ps1Dir 'register-pi-extension.ps1')
    } catch {
        Write-Warning "pi extension install failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Claude Code hooks
# ---------------------------------------------------------------------------
$settingsFile = Join-Path $env:USERPROFILE '.claude\settings.json'
$attention = (Join-Path $InstallDir 'attention.cmd').Replace('\', '\\')
$resume = (Join-Path $InstallDir 'resume.cmd').Replace('\', '\\')

if (-not (Test-Path -LiteralPath $settingsFile)) {
    Write-Warning "$settingsFile not found."
    Write-Host 'Create it manually or run Claude Code once first.'
} else {
    Write-Host ''
    Write-Host "Settings file exists at $settingsFile"
}
Write-Host ''
Write-Host 'Ensure settings.json has the following hooks registered:'
Write-Host ''
Write-Host '  "hooks": {'
Write-Host "    `"Stop`": [{`"matcher`": `"`", `"hooks`": [{`"type`": `"command`", `"command`": `"$attention`", `"timeout`": 10}]}],"
Write-Host "    `"UserPromptSubmit`": [{`"matcher`": `"`", `"hooks`": [{`"type`": `"command`", `"command`": `"$resume`", `"timeout`": 10}]}]"
Write-Host '  }'

Write-Host ''
Write-Host 'Installation complete.'
Write-Host ''
Write-Host 'NEXT STEPS:'
Write-Host '  1. Open each Claude Code tab in Windows Terminal'
Write-Host '  2. Make sure you are FOCUSED on that tab''s WT window'
Write-Host "  3. Run: powershell -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\setup.ps1`""
Write-Host '  4. Repeat for every Claude Code tab'
Write-Host ''
Write-Host 'Re-run setup.ps1 after: WT restart, tab reorder, adding/removing tabs.'
Write-Host ''
Write-Host 'Other agents:'
Write-Host '  Codex  - run /hooks in Codex to trust the two notification hooks'
Write-Host '  Cursor - hooks in ~/.cursor/hooks.json (stop, beforeSubmitPrompt)'
Write-Host '  pi     - extension in ~/.pi/agent/extensions; restart pi to load it'
