#Requires -Version 5.1
<#
.SYNOPSIS
Configure desktop notifications for the current Windows Terminal tab.

.DESCRIPTION
Captures the Windows Terminal window handle and the selected tab position for
the current WT_SESSION, so the notification hooks can target this exact tab.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1
Auto-detect the window and tab of the focused terminal.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 3 "Repos / Claude 1"
Override the tab index and give the tab a label.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 3 "Repos / Claude 1" 123456
Override the tab index, label and window handle (for automated launchers).
#>
param(
    [string]$TabIndex,
    [string]$Label,
    [string]$Hwnd,
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify')
)

$ErrorActionPreference = 'Stop'

$sessionId = $env:WT_SESSION
if (-not $sessionId) {
    Write-Error 'WT_SESSION not set. Run this from Windows Terminal.'
    exit 1
}

$hwndFile = Join-Path $InstallDir ".hwnd-$sessionId"
$tabIndexFile = Join-Path $InstallDir ".tabindex-$sessionId"
$labelFile = Join-Path $InstallDir ".label-$sessionId"

if ($Hwnd) {
    # Handle supplied by DevLayout or another automated launcher.
    [IO.File]::WriteAllText($hwndFile, $Hwnd)
} else {
    # Capture the current foreground window and its selected tab index.
    $saveHwnd = Join-Path $InstallDir 'save-hwnd.exe'
    if (-not (Test-Path -LiteralPath $saveHwnd)) {
        Write-Error "save-hwnd.exe not found at $saveHwnd. Re-run install.ps1."
        exit 1
    }
    & $saveHwnd

    $capturedHwnd = Join-Path $InstallDir '.hwnd'
    if (-not (Test-Path -LiteralPath $capturedHwnd)) {
        Write-Error 'Failed to capture window handle.'
        exit 1
    }
    Copy-Item -LiteralPath $capturedHwnd -Destination $hwndFile -Force
    $Hwnd = (Get-Content -LiteralPath $capturedHwnd -Raw).Trim()
}

if ($TabIndex) {
    [IO.File]::WriteAllText($tabIndexFile, $TabIndex)
} else {
    $capturedTab = Join-Path $InstallDir '.tabindex'
    if (-not (Test-Path -LiteralPath $capturedTab)) {
        Write-Error 'Failed to capture tab index.'
        exit 1
    }
    Copy-Item -LiteralPath $capturedTab -Destination $tabIndexFile -Force
    $TabIndex = (Get-Content -LiteralPath $capturedTab -Raw).Trim()
}

if ($Label) {
    [IO.File]::WriteAllText($labelFile, $Label)
}

Write-Host "Configured for session $sessionId"
Write-Host "  Window: $Hwnd"
Write-Host "  Tab index: $TabIndex"
if ($Label) { Write-Host "  Label: $Label" }
Write-Host ''
Write-Host 'Notifications will target this window and tab.'
Write-Host 'Re-run this command if you rearrange tabs or restart Windows Terminal.'
