#Requires -Version 5.1
<#
.SYNOPSIS
    One Windows Terminal window with three Claude Code tabs, one per
    PotatoSandwich clone.
.DESCRIPTION
    Tab 1 is the primary checkout, tabs 2 and 3 are the parallel clones in
    C:\repos2 and C:\repos3. Each tab has its own working directory, so each
    resolves its own ~/.claude/projects directory and its own conversation.

    This layout owns window slot 2. DevLayout.ps1 owns slot 1, ClaudeOrmiLayout.ps1
    owns slot 3 and ClaudeBothLayout.ps1 owns slot 4; two layouts sharing a slot would
    fight over the same saved sessions.
.PARAMETER DryRun
    Print the wt.exe command that would be run, then exit. Launches nothing.
#>

param(
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$Layout = @{
    Name          = "ClaudePotatoLayout"
    WindowNum     = 2
    TargetMonitor = 0
    SettleDelayMs = 150
    # Order is load-bearing: tab N owns session slot w2-tN.
    Tabs = @(
        @{ Title = "PS-1"; WorkingDir = "C:\Repos\PotatoSandwich" }
        @{ Title = "PS-2"; WorkingDir = "C:\repos2\PotatoSandwich2" }
        @{ Title = "PS-3"; WorkingDir = "C:\repos3\PotatoSandwich3" }
    )
}

Invoke-LayoutWindow -Layout $Layout -DryRun:$DryRun
