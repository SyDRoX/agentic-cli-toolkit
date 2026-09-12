#Requires -Version 5.1
<#
.SYNOPSIS
    Launch one or more Windows Terminal windows from a JSON custom-layout file.
.DESCRIPTION
    Used by layout_ui.py. Each window in the JSON becomes one Invoke-LayoutWindow
    call. Tabs may mix agents (Claude / Codex / Pi / Cursor).

    WindowNum values are load-bearing session namespaces; the UI assigns them
    and persists them in the preset so relaunches keep the same slots.
.PARAMETER ConfigPath
    Path to a JSON file (see custom-layouts/*.json).
.PARAMETER DryRun
    Print the planned launches without starting Terminal.
#>

param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$AgentMap = @{
    claude = @{ AgentName = "Claude"; LauncherScript = "launch-claude.ps1" }
    codex  = @{ AgentName = "Codex";  LauncherScript = "launch-codex.ps1" }
    pi     = @{ AgentName = "Pi";     LauncherScript = "launch-pi.ps1" }
    cursor = @{ AgentName = "Cursor"; LauncherScript = "launch-agent.ps1" }
    agent  = @{ AgentName = "Cursor"; LauncherScript = "launch-agent.ps1" }
}

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}

$config = Get-Content -Path $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $config.windows -or $config.windows.Count -eq 0) {
    Write-Error "Config '$ConfigPath' has no windows."
    exit 1
}

$stateDir = Join-Path $env:USERPROFILE ".dev-layout\custom"
$presetName = if ($config.name) { [string]$config.name } else { [IO.Path]::GetFileNameWithoutExtension($ConfigPath) }

Write-Host "Custom layout '$presetName': $($config.windows.Count) window(s)" -ForegroundColor Cyan

$index = 0
foreach ($win in $config.windows) {
    $index++
    if (-not $win.tabs -or $win.tabs.Count -eq 0) {
        Write-Warning "Skipping window $index - no tabs."
        continue
    }
    if (-not $win.windowNum) {
        Write-Error "Window $index has no windowNum; session slots would collide."
        exit 1
    }

    $tabs = @()
    foreach ($t in $win.tabs) {
        $agentKey = ([string]$t.agent).Trim().ToLowerInvariant()
        if (-not $AgentMap.ContainsKey($agentKey)) {
            Write-Error "Unknown agent '$($t.agent)' in window $index. Use: claude, codex, pi, cursor."
            exit 1
        }
        $mapped = $AgentMap[$agentKey]
        $tabs += @{
            Title          = [string]$t.title
            WorkingDir     = [string]$t.workingDir
            AgentName      = $mapped.AgentName
            LauncherScript = $mapped.LauncherScript
        }
    }

    $layout = @{
        Name          = if ($win.name) { [string]$win.name } else { "$presetName #$index" }
        WindowNum     = [int]$win.windowNum
        TargetMonitor = if ($null -ne $win.targetMonitor) { [int]$win.targetMonitor } else { 0 }
        SettleDelayMs = if ($win.settleDelayMs) { [int]$win.settleDelayMs } else { 150 }
        StateDir      = $stateDir
        Tabs          = $tabs
    }

    Invoke-LayoutWindow -Layout $layout -DryRun:$DryRun

    # Let the previous window settle so Find-NewTerminalWindow can tell them apart.
    if (-not $DryRun -and $index -lt $config.windows.Count) {
        Start-Sleep -Milliseconds 800
    }
}

Write-Host "Custom layout '$presetName': done." -ForegroundColor Green
