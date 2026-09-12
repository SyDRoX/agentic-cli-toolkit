#Requires -Version 5.1
param([switch]$DryRun)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$Layout = @{
    Name           = "CodexOrmiLayout"
    WindowNum      = 13
    TargetMonitor  = 0
    SettleDelayMs  = 150
    AgentName      = "Codex"
    LauncherScript = "launch-codex.ps1"
    StateDir       = (Join-Path $env:USERPROFILE ".codex\dev-layout")
    Tabs = @(
        @{ Title = "ORMI-1"; WorkingDir = "C:\Repos\ormi-unity" }
        @{ Title = "ORMI-2"; WorkingDir = "C:\repos2\ormi-unity2" }
        @{ Title = "ORMI-3"; WorkingDir = "C:\repos3\ormi-unity3" }
    )
}

Invoke-LayoutWindow -Layout $Layout -DryRun:$DryRun
