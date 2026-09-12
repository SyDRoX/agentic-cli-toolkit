#Requires -Version 5.1
# Shows real test popups on each monitor using two invisible test window handles.
# Does not change live configuration or capture/focus a user's terminal tab.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('claude-notify-ui-' + [guid]::NewGuid().ToString('N'))
$savedSession = $env:WT_SESSION
$forms = @()
$popupIds = @()
function Invoke-HookEvent([string]$Session, [string]$EventName) {
    $env:WT_SESSION = $Session
    $inputFile = Join-Path $testDir 'input.json'
    [IO.File]::WriteAllText($inputFile, ('{"hook_event_name":"' + $EventName + '"}'))
    $process = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $testDir 'codex-hook.ps1') + '"') `
        -RedirectStandardInput $inputFile -RedirectStandardOutput (Join-Path $testDir 'output.json') `
        -RedirectStandardError (Join-Path $testDir 'stderr.txt') -WindowStyle Hidden -PassThru
    $null = $process.Handle
    if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Hook timed out.' }
    if ($process.ExitCode -ne 0) { throw "Hook failed (exit $($process.ExitCode)): $(Get-Content (Join-Path $testDir 'stderr.txt') -Raw)" }
    if ((Get-Content (Join-Path $testDir 'output.json') -Raw).Trim() -ne '{}') { throw 'Invalid hook response.' }
}
function Get-SessionPopupIds([string]$Session) {
    $file = Join-Path $testDir ".popup-$Session.pid"
    if (Test-Path $file) {
        foreach ($line in (Get-Content $file -ErrorAction SilentlyContinue)) {
            if ($line.Trim()) { [int]$line }
        }
    }
}
try {
    $null = New-Item -ItemType Directory -Path $testDir
    foreach ($file in @('notify.ps1', 'popup.ps1', 'codex-hook.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $testDir
    }
    $sessions = @([guid]::NewGuid().ToString(), [guid]::NewGuid().ToString())
    $screenCount = [System.Windows.Forms.Screen]::AllScreens.Count
    foreach ($session in $sessions) {
        $form = New-Object System.Windows.Forms.Form
        $form.ShowInTaskbar = $false
        $forms += $form
        [IO.File]::WriteAllText((Join-Path $testDir ".hwnd-$session"), $form.Handle.ToInt64().ToString())
        [IO.File]::WriteAllText((Join-Path $testDir ".label-$session"), 'notification integration test')
        Invoke-HookEvent $session 'Stop'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 200
            $ids = @(Get-SessionPopupIds $session)
        } while ($ids.Count -lt $screenCount -and [DateTime]::UtcNow -lt $deadline)
        $popupIds += $ids
        if ($ids.Count -ne $screenCount) { throw "Expected $screenCount popups for $session; got $($ids.Count)." }
        foreach ($popupId in $ids) {
            $foundTitle = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 200
                $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
                    [System.Windows.Automation.TreeScope]::Children,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $popupId))
                foreach ($window in $windows) {
                    $title = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.PropertyCondition]::new(
                            [System.Windows.Automation.AutomationElement]::NameProperty, 'Codex - notification integration test'))
                    if ($title) { $foundTitle = $true }
                }
            } while (-not $foundTitle -and [DateTime]::UtcNow -lt $deadline)
            if (-not $foundTitle) { throw "Codex popup title not found for process $popupId." }
        }
    }
    $firstIds = @(Get-SessionPopupIds $sessions[0])
    $secondIds = @(Get-SessionPopupIds $sessions[1])
    Invoke-HookEvent $sessions[0] 'UserPromptSubmit'
    foreach ($popupId in $firstIds) {
        if (Get-Process -Id $popupId -ErrorAction SilentlyContinue) { throw 'First session popup was not dismissed.' }
    }
    foreach ($popupId in $secondIds) {
        if (-not (Get-Process -Id $popupId -ErrorAction SilentlyContinue)) { throw 'Second session popup was incorrectly dismissed.' }
    }
    Invoke-HookEvent $sessions[1] 'UserPromptSubmit'
    foreach ($popupId in $secondIds) {
        if (Get-Process -Id $popupId -ErrorAction SilentlyContinue) { throw 'Second session popup was not dismissed.' }
    }
    if (Test-Path (Join-Path $testDir 'popup-crash.log')) { throw 'Popup crash log was created.' }
    Write-Host "PASS: two concurrent sessions, $screenCount monitors, Codex popup titles, independent dismissal, no WPF crashes."
} finally {
    $env:WT_SESSION = $savedSession
    # Only terminate processes recorded by this test's copied popup scripts.
    foreach ($file in (Get-ChildItem $testDir -Filter '.popup-*.pid' -ErrorAction SilentlyContinue)) {
        foreach ($line in (Get-Content $file.FullName -ErrorAction SilentlyContinue)) { if ($line.Trim()) { $popupIds += [int]$line } }
    }
    foreach ($popupId in ($popupIds | Select-Object -Unique)) { Stop-Process -Id $popupId -ErrorAction SilentlyContinue }
    foreach ($form in $forms) { $form.Dispose() }
    $resolvedTest = [IO.Path]::GetFullPath($testDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTest.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTest -Leaf) -like 'claude-notify-ui-*') {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
