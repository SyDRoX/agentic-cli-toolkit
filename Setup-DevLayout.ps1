#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the DevLayout session-resume hook.
.DESCRIPTION
    1. Copies devlayout-session-save.ps1 to ~/.claude/hooks/
    2. Creates the state directory ~/.claude/dev-layout/
    3. Registers the SessionStart hook in ~/.claude/settings.json (via Node,
       so only that one key is touched and the file keeps its formatting)

    Upstream also installed a cd-blocking PreToolUse hook into every workspace.
    That is intentionally omitted here: each tab is scoped to a single repo, so
    the multi-repo rationale for blocking cd does not apply.
.NOTES
    Idempotent. Re-run after editing hooks/devlayout-session-save.ps1.
#>

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$HookSource = Join-Path $ScriptDir "hooks\devlayout-session-save.ps1"
$HooksDir   = Join-Path $env:USERPROFILE ".claude\hooks"
$HookDest   = Join-Path $HooksDir "devlayout-session-save.ps1"
$StateDir   = Join-Path $env:USERPROFILE ".claude\dev-layout"
$Registrar  = Join-Path $ScriptDir "register-session-hook.js"

if (-not (Test-Path $HookSource)) {
    Write-Error "Hook script not found: $HookSource"
    exit 1
}

# 1. Hook script
if (-not (Test-Path $HooksDir)) {
    New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null
}
Copy-Item $HookSource $HookDest -Force
Write-Host "Session hook installed: $HookDest" -ForegroundColor Green

# 2. State directory. Upstream wrote state into ~/.claude/hooks/agentic-cli-notify,
#    a directory that ships with a different project - if it was missing, every
#    session save failed silently and nothing ever resumed.
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}
Write-Host "State directory ready: $StateDir" -ForegroundColor Green

# 3. Register in settings.json
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "node not found on PATH; cannot register the hook safely."
    exit 1
}
node $Registrar
if ($LASTEXITCODE -ne 0) {
    Write-Error "Hook registration failed."
    exit 1
}

Write-Host ""
Write-Host "Setup complete. Launch with:" -ForegroundColor Green
Write-Host "  cmd /c `"$ScriptDir\LayoutUI.bat`"" -ForegroundColor Cyan
Write-Host "Optional hotkey (Ctrl+Alt+D):" -ForegroundColor Green
Write-Host "  pwsh -ExecutionPolicy Bypass -File `"$ScriptDir\Setup-DevLayoutShortcut.ps1`"" -ForegroundColor Cyan
