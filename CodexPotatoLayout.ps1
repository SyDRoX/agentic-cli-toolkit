#Requires -Version 5.1
param([switch]$DryRun)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$Layout = @{
    Name           = "CodexPotatoLayout"
    WindowNum      = 12
    TargetMonitor  = 0
    SettleDelayMs  = 150
    AgentName      = "Codex"
    LauncherScript = "launch-codex.ps1"
    StateDir       = (Join-Path $env:USERPROFILE ".codex\dev-layout")
    Tabs = @(
        @{ Title = "PS-1"; WorkingDir = "C:\Repos\PotatoSandwich" }
        @{ Title = "PS-2"; WorkingDir = "C:\repos2\PotatoSandwich2" }
        @{ Title = "PS-3"; WorkingDir = "C:\repos3\PotatoSandwich3" }
    )
}

Invoke-LayoutWindow -Layout $Layout -DryRun:$DryRun
