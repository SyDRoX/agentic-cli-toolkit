#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a Ctrl+Alt+D shortcut for the agentic CLI layout composer.
.DESCRIPTION
    Creates a shortcut in the Start Menu Programs folder (required for Windows
    keyboard shortcuts to work). Pass -Desktop to also drop one on the desktop.
.PARAMETER Desktop
    Also create a desktop shortcut. Upstream asked interactively via Read-Host,
    which hangs when the script is run non-interactively.
#>

param(
    [switch]$Desktop
)

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BatPath      = Join-Path $ScriptDir "LayoutUI.bat"
$ShortcutDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $ShortcutDir "AgenticCliToolkit.lnk"

if (-not (Test-Path $BatPath)) {
    Write-Error "LayoutUI.bat not found at: $BatPath"
    exit 1
}

$WScriptShell = New-Object -ComObject WScript.Shell

$Shortcut = $WScriptShell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath       = $BatPath
$Shortcut.WorkingDirectory = $ScriptDir
$Shortcut.Description      = "Open the agentic CLI layout composer"
$Shortcut.WindowStyle      = 7  # Minimized
$Shortcut.Hotkey           = "Ctrl+Alt+D"
$Shortcut.Save()

Write-Host "Shortcut created: $ShortcutPath" -ForegroundColor Green
Write-Host "Hotkey: Ctrl+Alt+D" -ForegroundColor Cyan

if ($Desktop) {
    $DesktopPath = "$env:USERPROFILE\Desktop\AgenticCliToolkit.lnk"
    $DesktopShortcut = $WScriptShell.CreateShortcut($DesktopPath)
    $DesktopShortcut.TargetPath       = $BatPath
    $DesktopShortcut.WorkingDirectory = $ScriptDir
    $DesktopShortcut.Description      = "Open the agentic CLI layout composer"
    $DesktopShortcut.WindowStyle      = 7
    $DesktopShortcut.Save()
    Write-Host "Desktop shortcut created: $DesktopPath" -ForegroundColor Green
}

[System.Runtime.Interopservices.Marshal]::ReleaseComObject($WScriptShell) | Out-Null
