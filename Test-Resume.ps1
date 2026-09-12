#Requires -Version 5.1
<#
.SYNOPSIS
    Dry-runs the session-resume decision for every DevLayout tab.
.DESCRIPTION
    Uses the same SessionSlot.ps1 resolution logic as launch-claude.ps1, but
    prints the decision instead of launching Claude. Run it to see which
    conversation each tab will reopen, or to debug a tab that starts fresh when
    you expected it to resume.
#>

. (Join-Path $PSScriptRoot "SessionSlot.ps1")

$Tabs = @(
    "C:\Repos\ormi-unity",
    "C:\Repos\PotatoSandwich",
    "C:\Repos\WaaaghGamez",
    "C:\Repos\DefendYourCastle3D"
)
$WindowNum = 1
$StateDir  = Join-Path $env:USERPROFILE ".claude\dev-layout"

Write-Host ""
Write-Host "DevLayout resume dry-run   state dir: $StateDir" -ForegroundColor Cyan

for ($i = 0; $i -lt $Tabs.Count; $i++) {
    $tabIndex = $i + 1
    $cwd      = $Tabs[$i].TrimEnd('\')

    $slot = Resolve-SlotResume -WindowNum $WindowNum -TabIndex $tabIndex `
                               -WorkingDir $cwd -StateDir $StateDir

    Write-Host ""
    Write-Host "--- Tab $tabIndex : $cwd" -ForegroundColor Cyan
    Write-Host "    slot          : devlayout-w$WindowNum-t$tabIndex"
    Write-Host "    slot UUID     : $($slot.DefaultSessionId)"

    if (-not (Test-Path $cwd)) {
        Write-Host "    repo          : MISSING" -ForegroundColor Red
    }

    if (Test-Path $slot.ProjectPath) {
        $count = @(Get-ChildItem $slot.ProjectPath -Filter *.jsonl -ErrorAction SilentlyContinue).Count
        Write-Host "    project dir   : exists, $count transcript(s)" -ForegroundColor Green
    } else {
        Write-Host "    project dir   : not created yet (first run here)" -ForegroundColor Yellow
    }

    if ($slot.StateRaw) {
        if ($slot.Source -like 'state file*') {
            Write-Host "    state file    : $($slot.StateRaw)" -ForegroundColor Green
        } else {
            Write-Host "    state file    : $($slot.StateRaw)  IGNORED - no matching transcript in this repo" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    state file    : none"
    }

    if ($slot.ResumeId) {
        Write-Host "    DECISION      : RESUME $($slot.ResumeId)" -ForegroundColor Green
        Write-Host "                    source: $($slot.Source)"
    } else {
        Write-Host "    DECISION      : NEW session pinned to $($slot.DefaultSessionId)" -ForegroundColor Yellow
        Write-Host "                    next launch will resume this id"
    }
}

Write-Host ""
