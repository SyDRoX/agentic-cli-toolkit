#Requires -Version 5.1
# Isolated tests for the notify command and the session registry.
# Uses a temporary state directory and fake agents; opens no windows, closes no
# tabs, and never touches the live registry.
$ErrorActionPreference = 'Stop'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('agentic-cli-notify-cli-' + [guid]::NewGuid().ToString('N'))
$savedSession = $env:WT_SESSION
$savedNotifyDir = $env:AGENTIC_NOTIFY_DIR
$savedPath = $env:Path
$cli = Join-Path $PSScriptRoot 'notify-cli.ps1'

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Arguments([string[]]$Actual, [string[]]$Expected, [string]$Message) {
    Assert (($Actual -join '|') -ceq ($Expected -join '|')) "$Message`n  expected: $($Expected -join ' ')`n  actual:   $($Actual -join ' ')"
}

try {
    $null = New-Item -ItemType Directory -Path $testDir
    $fakeBin = Join-Path $testDir 'fake bin'
    $null = New-Item -ItemType Directory -Path $fakeBin
    $env:AGENTIC_NOTIFY_DIR = $testDir
    . (Join-Path $PSScriptRoot 'SessionRegistry.ps1')

    # --- resume arguments ------------------------------------------------
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--dangerously-skip-permissions') -ConversationId 'abc') `
        @('--resume', 'abc', '--dangerously-skip-permissions') 'Claude: flags must be kept.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--continue', '--model', 'opus', '--resume', 'old', '--session-id', 'x') -ConversationId 'abc') `
        @('--resume', 'abc', '--model', 'opus') 'Claude: old session flags must be dropped.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--model', 'opus', 'fix the build') -ConversationId 'abc') `
        @('--resume', 'abc', '--model', 'opus') 'Claude: a start-up prompt must not be replayed.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--dangerously-skip-permissions', 'fix the build') -ConversationId 'abc') `
        @('--resume', 'abc', '--dangerously-skip-permissions') 'Claude: a prompt after a boolean flag must not be replayed.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--append-system-prompt', 'be terse') -ConversationId 'abc') `
        @('--resume', 'abc', '--append-system-prompt', 'be terse') 'Claude: a flag value with spaces must be kept.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @('--continue', '--model', 'opus') -ConversationId '') `
        @('--continue', '--model', 'opus') 'No conversation id: arguments must be returned unchanged.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Claude -Arguments @() -ConversationId 'abc') `
        @('--resume', 'abc') 'Claude: no arguments.'

    Assert-Arguments (Get-AgentResumeArguments -Agent Codex -Arguments @('--dangerously-bypass-approvals-and-sandbox', '-c', 'model=gpt-5.6') -ConversationId 'id1') `
        @('resume', 'id1', '--dangerously-bypass-approvals-and-sandbox', '-c', 'model=gpt-5.6') 'Codex: -c config overrides must be kept.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Codex -Arguments @('resume', '--last', '-C', 'C:\x', '-m', 'gpt-5.6') -ConversationId 'id1') `
        @('resume', 'id1', '-C', 'C:\x', '-c', 'model=gpt-5.6') 'Codex: resume --last must be replaced and -m converted; -C must survive.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Codex -Arguments @('resume', '01a1d123-0c0f-7863-a3b4-eb82fe270583') -ConversationId 'id1') `
        @('resume', 'id1') 'Codex: an old session id must be replaced.'

    Assert-Arguments (Get-AgentResumeArguments -Agent Pi -Arguments @('--continue', '--model', 'gpt-5.6-luna:medium') -ConversationId 'p1') `
        @('--session', 'p1', '--model', 'gpt-5.6-luna:medium') 'pi: --continue must be replaced.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Pi -Arguments @('-c', '--session', 'old', '--thinking', 'high') -ConversationId 'p1') `
        @('--session', 'p1', '--thinking', 'high') 'pi: -c and --session must be dropped.'

    Assert-Arguments (Get-AgentResumeArguments -Agent Cursor -Arguments @('--continue', '-f') -ConversationId 'c1') `
        @('--resume', 'c1', '-f') 'Cursor: --continue must be replaced.'
    Assert-Arguments (Get-AgentResumeArguments -Agent Other -Arguments @('--flag') -ConversationId 'x') `
        @('--flag') 'Unknown agent: arguments must be returned unchanged.'

    # --- launch: argument passthrough and registration -------------------
    # A fake claude that records what it received and what the registry held
    # while it ran. Named claude.ps1 so the wrapper classifies it as Claude.
    @'
[IO.File]::WriteAllText((Join-Path $env:AGENTIC_NOTIFY_DIR 'received.txt'), ($args -join "`n"))
$record = Join-Path $env:AGENTIC_NOTIFY_DIR ".sessions\$($env:WT_SESSION).json"
if (Test-Path -LiteralPath $record) { Copy-Item -LiteralPath $record -Destination (Join-Path $env:AGENTIC_NOTIFY_DIR 'record-during.json') }
[IO.File]::WriteAllText((Join-Path $env:AGENTIC_NOTIFY_DIR 'claudecode.txt'), "[$env:CLAUDECODE]")
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath (Join-Path $fakeBin 'claude.ps1')
    $env:Path = "$fakeBin;$env:Path"
    $env:WT_SESSION = 'test-session-cli'
    $env:CLAUDECODE = '1'

    & $cli claude --dangerously-skip-permissions -c --model 'opus[1m]' 'two words' *> $null
    $env:AGENTIC_NOTIFY_DIR = $testDir

    $received = @(Get-Content -LiteralPath (Join-Path $testDir 'received.txt'))
    Assert-Arguments $received @('--dangerously-skip-permissions', '-c', '--model', 'opus[1m]', 'two words') 'Agent flags must pass through untouched.'
    Assert ((Get-Content -LiteralPath (Join-Path $testDir 'claudecode.txt') -Raw) -eq '[]') 'CLAUDECODE must be cleared before the agent starts.'

    $record = Get-Content -LiteralPath (Join-Path $testDir 'record-during.json') -Raw | ConvertFrom-Json
    Assert ($record.agent -eq 'Claude' -and $record.command -eq 'claude') 'Record must name the agent and command.'
    Assert-Arguments @($record.args) @('--dangerously-skip-permissions', '-c', '--model', 'opus[1m]', 'two words') 'Record must keep the arguments.'
    Assert ([int]$record.shellPid -eq $PID) 'Record must hold the shell process id.'
    Assert ($record.cwd -eq (Get-Location).ProviderPath) 'Record must hold the working directory.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $testDir '.sessions\test-session-cli.json'))) 'Record must be removed when the agent exits.'

    # --- registry: live sessions, hook side files, pruning ---------------
    $null = Register-AgentSession -Agent Codex -Command codex -Arguments @('-c', 'model=x')
    $registryDir = Get-SessionRegistryDir
    [IO.File]::WriteAllText((Join-Path $registryDir 'test-session-cli.state'), 'busy')
    [IO.File]::WriteAllText((Join-Path $registryDir 'test-session-cli.conv'), 'Codex|conv-1')
    $live = @(Get-AgentSessions)
    Assert ($live.Count -eq 1 -and $live[0].state -eq 'busy' -and $live[0].conversation -eq 'conv-1') 'Live session must carry hook state and conversation.'

    [IO.File]::WriteAllText((Join-Path $registryDir 'test-session-cli.conv'), 'Claude|other-agent')
    Assert ($null -eq @(Get-AgentSessions)[0].conversation) 'A conversation id from another agent must be ignored.'

    # A record whose shell is gone: same pid, different start time.
    $dead = Get-Content -LiteralPath (Join-Path $registryDir 'test-session-cli.json') -Raw | ConvertFrom-Json
    $dead.sessionId = 'test-session-dead'
    $dead.shellStartTicks = '1'
    [IO.File]::WriteAllText((Join-Path $registryDir 'test-session-dead.json'), ($dead | ConvertTo-Json -Depth 4))
    Assert (@(Get-AgentSessions).Count -eq 1) 'A record of a dead shell must not be listed.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $registryDir 'test-session-dead.json'))) 'A record of a dead shell must be pruned.'

    # --- hook: notify.ps1 writes state and conversation ------------------
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'notify.ps1') -Destination $testDir
    $notify = Join-Path $testDir 'notify.ps1'
    Remove-Item -LiteralPath (Join-Path $registryDir 'test-session-cli.state'), (Join-Path $registryDir 'test-session-cli.conv') -Force
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notify -Action resume -Agent Codex -ConversationId 'conv-2' | Out-Null
    $live = @(Get-AgentSessions)
    Assert ($live[0].state -eq 'busy' -and $live[0].conversation -eq 'conv-2') 'resume must mark the tab busy and store the conversation.'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notify -Action resume -Agent Codex -Idle | Out-Null
    Assert (@(Get-AgentSessions)[0].state -eq 'idle') 'resume -Idle must mark the tab idle.'
    # attention with no saved window handle exits before any flash or popup.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notify -Action resume -Agent Codex | Out-Null
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notify -Action attention -Agent Codex | Out-Null
    Assert (@(Get-AgentSessions)[0].state -eq 'idle') 'attention must mark the tab idle.'
    $env:WT_SESSION = 'test-session-unregistered'
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $notify -Action resume -Agent Codex -ConversationId 'conv-3' | Out-Null
    Assert (-not (Test-Path -LiteralPath (Join-Path $registryDir 'test-session-unregistered.state'))) 'Hooks must not track unregistered tabs.'
    $env:WT_SESSION = 'test-session-cli'

    # --- close: dry run and the mid-turn guard ---------------------------
    # The only registered tab is this very shell, which close must never kill.
    $output = (& $cli close -DryRun *>&1 | Out-String)
    $env:AGENTIC_NOTIFY_DIR = $testDir
    Assert ($output -match 'skipping this tab') "close must skip the tab it runs in: $output"
    Assert (Test-Path -LiteralPath (Join-Path $registryDir 'test-session-cli.json')) 'close -DryRun must not unregister anything.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $registryDir 'snapshots'))) 'close -DryRun must not write a snapshot.'
    Unregister-AgentSession -SessionId 'test-session-cli'

    # --- restore: dry run from a hand-written snapshot -------------------
    $snapshot = [ordered]@{
        version = 1
        createdUtc = [DateTime]::UtcNow.ToString('o')
        windows = @(
            [ordered]@{
                hwnd = 1; maximized = $true; rect = $null
                tabs = @(
                    [ordered]@{ agent = 'Claude'; command = 'claude'; args = @('--dangerously-skip-permissions'); cwd = 'C:\Repos\a'; shell = ''; title = $null; launcher = $null; launcherArgs = @(); conversation = 'conv-a' },
                    [ordered]@{ agent = 'Pi'; command = 'pi'; args = @('--continue'); cwd = 'C:\Repos\b'; shell = ''; title = $null; launcher = $null; launcherArgs = @(); conversation = $null }
                )
            }
        )
    }
    $snapshotPath = Join-Path $testDir 'snapshot.json'
    [IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 8))
    $output = (& $cli restore -Snapshot $snapshotPath -DryRun *>&1 | Out-String)
    $env:AGENTIC_NOTIFY_DIR = $testDir
    Assert ($output -match 'claude --resume conv-a --dangerously-skip-permissions') "restore must plan an exact Claude resume: $output"
    Assert ($output -match 'pi --continue') "restore must keep the original arguments when no conversation is known: $output"
    Assert (Test-Path -LiteralPath $snapshotPath) 'restore -DryRun must leave the snapshot in place.'

    $output = (& $cli restore -DryRun *>&1 | Out-String)
    $env:AGENTIC_NOTIFY_DIR = $testDir
    Assert ($output -match 'nothing to restore') "restore without a snapshot must say so: $output"

    Write-Host 'PASS: resume arguments, flag passthrough, registration, pruning, hook state, close guard, restore plan.'
} finally {
    $env:WT_SESSION = $savedSession
    $env:AGENTIC_NOTIFY_DIR = $savedNotifyDir
    $env:Path = $savedPath
    Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
    $resolvedTest = [IO.Path]::GetFullPath($testDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTest.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedTest -Leaf) -like 'agentic-cli-notify-cli-*') {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
