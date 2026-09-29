#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a Ctrl+Alt+D shortcut for the agentic CLI toolkit.
.DESCRIPTION
    Creates a shortcut in the Start Menu Programs folder (required for Windows
    keyboard shortcuts to work). Pass -Desktop to also drop one on the desktop.

    Without -Preset the hotkey opens the layout composer UI. With -Preset it
    launches that layout directly through Invoke-CustomLayout.ps1, no UI.
.PARAMETER Preset
    Layout to launch on the hotkey: a preset name from custom-layouts\ (without
    .json) or a path to a layout JSON file.
.PARAMETER Desktop
    Also create a desktop shortcut. Upstream asked interactively via Read-Host,
    which hangs when the script is run non-interactively.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\ps1-scripts\Setup-DevLayoutShortcut.ps1 -Preset DevLayout
#>

param(
    [string]$Preset,
    [switch]$Desktop
)

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ToolkitDir   = Split-Path -Parent $ScriptDir
$ShortcutDir  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $ShortcutDir "AgenticCliToolkit.lnk"

if ($Preset) {
    $PresetPath = $Preset
    if (-not (Test-Path $PresetPath)) {
        $PresetPath = Join-Path $ToolkitDir "custom-layouts\$Preset.json"
    }
    if (-not (Test-Path $PresetPath)) {
        Write-Error "Preset not found: $Preset (also tried $PresetPath)"
        exit 1
    }
    $PresetPath  = (Resolve-Path $PresetPath).Path
    $LayoutScript = Join-Path $ScriptDir "Invoke-CustomLayout.ps1"
    $TargetPath  = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
    $Arguments   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LayoutScript`" -ConfigPath `"$PresetPath`""
    $Description = "Launch agentic CLI layout: $([IO.Path]::GetFileNameWithoutExtension($PresetPath))"
} else {
    $TargetPath = Join-Path $ToolkitDir "LayoutUI.bat"
    if (-not (Test-Path $TargetPath)) {
        Write-Error "LayoutUI.bat not found at: $TargetPath"
        exit 1
    }
    $Arguments   = ""
    $Description = "Open the agentic CLI layout composer"
}

$WScriptShell = New-Object -ComObject WScript.Shell

function New-ToolkitShortcut {
    param([string]$Path, [bool]$WithHotkey)

    $Shortcut = $WScriptShell.CreateShortcut($Path)
    $Shortcut.TargetPath       = $TargetPath
    $Shortcut.Arguments        = $Arguments
    $Shortcut.WorkingDirectory = $ToolkitDir
    $Shortcut.Description      = $Description
    $Shortcut.WindowStyle      = 7  # Minimized
    if ($WithHotkey) { $Shortcut.Hotkey = "Ctrl+Alt+D" }
    $Shortcut.Save()
}

New-ToolkitShortcut -Path $ShortcutPath -WithHotkey $true
Write-Host "Shortcut created: $ShortcutPath" -ForegroundColor Green
Write-Host "Hotkey: Ctrl+Alt+D -> $Description" -ForegroundColor Cyan

if ($Desktop) {
    $DesktopPath = "$env:USERPROFILE\Desktop\AgenticCliToolkit.lnk"
    New-ToolkitShortcut -Path $DesktopPath -WithHotkey $false
    Write-Host "Desktop shortcut created: $DesktopPath" -ForegroundColor Green
}

[System.Runtime.Interopservices.Marshal]::ReleaseComObject($WScriptShell) | Out-Null
