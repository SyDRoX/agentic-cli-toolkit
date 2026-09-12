#Requires -Version 5.1
<#
.SYNOPSIS
    One Windows Terminal window with three Claude Code tabs, one per ormi-unity
    clone.
.DESCRIPTION
    Tab 1 is the primary checkout, tabs 2 and 3 are the parallel clones in
    C:\repos2 and C:\repos3. Each tab has its own working directory, so each
    resolves its own ~/.claude/projects directory and its own conversation.

    This layout owns window slot 3. DevLayout.ps1 owns slot 1, ClaudePotatoLayout.ps1
    owns slot 2 and ClaudeBothLayout.ps1 owns slot 4; two layouts sharing a slot would
    fight over the same saved sessions.
.PARAMETER DryRun
    Print the wt.exe command that would be run, then exit. Launches nothing.
#>

param(
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$Layout = @{
    Name          = "ClaudeOrmiLayout"
    WindowNum     = 3
    TargetMonitor = 0
    SettleDelayMs = 150
    # Order is load-bearing: tab N owns session slot w3-tN.
    Tabs = @(
        @{ Title = "ORMI-1"; WorkingDir = "C:\Repos\ormi-unity" }
        @{ Title = "ORMI-2"; WorkingDir = "C:\repos2\ormi-unity2" }
        @{ Title = "ORMI-3"; WorkingDir = "C:\repos3\ormi-unity3" }
    )
}

Invoke-LayoutWindow -Layout $Layout -DryRun:$DryRun
