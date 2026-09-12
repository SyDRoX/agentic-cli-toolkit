#Requires -Version 5.1
# Isolated contract tests. No live config edits, taskbar flashes, or popups.
$ErrorActionPreference = 'Stop'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('agentic-cli-notify-tests-' + [guid]::NewGuid().ToString('N'))
$notifyDir = Join-Path $testDir 'scripts with spaces'
$codexDir = Join-Path $testDir 'codex'
$savedSession = $env:WT_SESSION
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-TestHook([string]$Payload) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $notifyDir 'codex-hook.ps1') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($info)
    $proc.StandardInput.Write($Payload)
    $proc.StandardInput.Close()
    $output = $proc.StandardOutput.ReadToEnd()
    $errors = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    Assert ($proc.ExitCode -eq 0) 'Hook must exit successfully.'
    Assert ($output.Trim() -eq '{}') "Hook must return only empty JSON: $output"
    Assert (-not $errors) "Unexpected hook stderr: $errors"
    $proc.Dispose()
}
try {
    $null = New-Item -ItemType Directory -Path $notifyDir, $codexDir -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'codex-hook.ps1') -Destination $notifyDir
    @'
param($Action, $Agent)
Add-Content -LiteralPath (Join-Path $PSScriptRoot ('events-' + $env:WT_SESSION)) -Value "$Action/$Agent"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $notifyDir 'notify.ps1')
    $env:WT_SESSION = 'test-session-a'
    Invoke-TestHook '{"hook_event_name":"Stop"}'
    $env:WT_SESSION = 'test-session-b'
    Invoke-TestHook '{"hook_event_name":"Stop"}'
    $env:WT_SESSION = 'test-session-a'
    Invoke-TestHook '{"hook_event_name":"UserPromptSubmit"}'
    Invoke-TestHook '{"hook_event_name":"SubagentStop"}'
    Invoke-TestHook 'not json'
    Assert (((Get-Content (Join-Path $notifyDir 'events-test-session-a')) -join ',') -eq 'attention/Codex,resume/Codex') 'Session A routing failed.'
    Assert ((Get-Content (Join-Path $notifyDir 'events-test-session-b')) -eq 'attention/Codex') 'Session B must remain isolated.'
    $env:WT_SESSION = $null
    Invoke-TestHook '{"hook_event_name":"Stop"}'
    $env:WT_SESSION = '../invalid'
    Invoke-TestHook '{"hook_event_name":"Stop"}'
    Assert (@(Get-ChildItem $notifyDir -Filter 'events-*').Count -eq 2) 'Invalid sessions must not dispatch.'
    'throw "simulated notification failure"' | Set-Content (Join-Path $notifyDir 'notify.ps1')
    $env:WT_SESSION = 'test-session-a'
    Invoke-TestHook '{"hook_event_name":"Stop"}'

    $settingsPath = Join-Path $codexDir 'hooks.json'
    $original = '{"extra":{"keep":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-hook"}]}],"SessionStart":[]}}'
    [IO.File]::WriteAllText($settingsPath, $original)
    $registrar = Join-Path $PSScriptRoot 'register-codex-hooks.ps1'
    & $registrar -CodexDir $codexDir -NotifyDir $notifyDir
    $first = [IO.File]::ReadAllText($settingsPath)
    $settings = $first | ConvertFrom-Json
    Assert ($settings.extra.keep -and $settings.hooks.Stop[0].hooks[0].command -eq 'existing-hook') 'Existing settings must be preserved.'
    Assert ($settings.hooks.Stop.Count -eq 2 -and $settings.hooks.UserPromptSubmit.Count -eq 1) 'Expected both lifecycle hooks.'
    Assert ($settings.hooks.Stop[1].hooks[0].command.Contains('"' + $notifyDir)) 'Hook path with spaces must be quoted.'
    & $registrar -CodexDir $codexDir -NotifyDir $notifyDir
    Assert ([IO.File]::ReadAllText($settingsPath) -ceq $first) 'Registration must be idempotent.'
    $backups = @(Get-ChildItem $codexDir -Filter '*.bak-*')
    Assert ($backups.Count -eq 1) 'Only a changed registration should make a backup.'
    Assert ([IO.File]::ReadAllText($backups[0].FullName) -ceq $original) 'Backup must preserve original bytes.'
    [IO.File]::WriteAllText($settingsPath, '{invalid')
    $failed = $false
    try { & $registrar -CodexDir $codexDir -NotifyDir $notifyDir } catch { $failed = $true }
    Assert $failed 'Malformed settings must reject registration.'
    Assert ([IO.File]::ReadAllText($settingsPath) -ceq '{invalid') 'Malformed settings must remain untouched.'
    Write-Host 'PASS: routing, session isolation, fail-open behavior, JSON output, registration, preservation, backup, and idempotency.'
} finally {
    $env:WT_SESSION = $savedSession
    $resolvedTest = [IO.Path]::GetFullPath($testDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTest.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTest -Leaf) -like 'agentic-cli-notify-tests-*') {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
