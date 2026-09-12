#Requires -Version 5.1
<#
.SYNOPSIS
    One Windows Terminal window with six Claude Code tabs: three PotatoSandwich
    clones followed by three ormi-unity clones.
.DESCRIPTION
    The combined variant of ClaudePotatoLayout.ps1 and ClaudeOrmiLayout.ps1 - same six
    repos, one window instead of two.

    This layout owns window slot 4, so its six conversations are separate from
    the ones the per-game layouts use. Running ClaudeBothLayout and then ClaudePotatoLayout
    gives two independent sets of PotatoSandwich sessions, which is deliberate:
    a slot is defined by (window, tab), not by directory.
.PARAMETER DryRun
    Print the wt.exe command that would be run, then exit. Launches nothing.
#>

param(
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot "LayoutEngine.ps1")

$Layout = @{
    Name          = "ClaudeBothLayout"
    WindowNum     = 4
    TargetMonitor = 0
    SettleDelayMs = 150
    # Order is load-bearing: tab N owns session slot w4-tN.
    Tabs = @(
        @{ Title = "PS-1";   WorkingDir = "C:\Repos\PotatoSandwich" }
        @{ Title = "PS-2";   WorkingDir = "C:\repos2\PotatoSandwich2" }
        @{ Title = "PS-3";   WorkingDir = "C:\repos3\PotatoSandwich3" }
        @{ Title = "ORMI-1"; WorkingDir = "C:\Repos\ormi-unity" }
        @{ Title = "ORMI-2"; WorkingDir = "C:\repos2\ormi-unity2" }
        @{ Title = "ORMI-3"; WorkingDir = "C:\repos3\ormi-unity3" }
    )
}

Invoke-LayoutWindow -Layout $Layout -DryRun:$DryRun
