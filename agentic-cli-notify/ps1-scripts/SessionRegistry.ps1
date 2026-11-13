#Requires -Version 5.1
# Session registry shared by the `notify` command and the layout launchers.
#
# One record per Windows Terminal tab that runs an agent, keyed by WT_SESSION
# like every other notification state file:
#
#   .sessions\<session>.json   what to relaunch (command, arguments, working dir)
#   .sessions\<session>.state  "busy" or "idle", written by the hooks
#   .sessions\<session>.conv   "<Agent>|<conversation id>", written by the hooks
#   .sessions\closed\<session>.json   tabs closed under a running agent (notify reopen)
#
# The hooks write the two side files instead of rewriting the record, so a hook
# never has to parse JSON or race the launcher over one file.
#
# Every function here swallows its own errors: a registry failure must never
# stop an agent from launching.

function Get-AgenticNotifyDir {
    if ($env:AGENTIC_NOTIFY_DIR) { return $env:AGENTIC_NOTIFY_DIR }
    return $PSScriptRoot
}

function Get-SessionRegistryDir {
    return (Join-Path (Get-AgenticNotifyDir) '.sessions')
}

function Test-SessionKey {
    param([string]$SessionId)
    return ($SessionId -match '^[A-Za-z0-9-]+$')
}

function Write-RegistryText {
    # Write through a temp file so a reader never sees half a record.
    param([string]$Path, [string]$Text)
    $temp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Register-AgentSession {
    <#
    .SYNOPSIS
        Record the agent this tab is about to run. Returns the session id, or
        $null outside Windows Terminal.
    .PARAMETER Launcher
        Layout launcher script that owns this tab. Restore reruns the launcher
        with LauncherArguments instead of Command, so slot rules keep applying.
    #>
    param(
        [string]$Agent,
        [string]$Command,
        [string[]]$Arguments,
        [string]$Title,
        [string]$Launcher,
        [string[]]$LauncherArguments
    )

    try {
        $sessionId = $env:WT_SESSION
        if (-not (Test-SessionKey $sessionId)) { return $null }

        $dir = Get-SessionRegistryDir
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

        $self = Get-Process -Id $PID
        $record = [ordered]@{
            sessionId       = $sessionId
            agent           = $Agent
            command         = $Command
            args            = if ($Arguments) { @($Arguments) } else { @() }
            cwd             = (Get-Location).ProviderPath
            shell           = $self.Path
            shellPid        = $PID
            # A string: 18-digit tick counts do not survive every JSON parser as a number.
            shellStartTicks = $self.StartTime.ToUniversalTime().Ticks.ToString()
            startedUtc      = [DateTime]::UtcNow.ToString('o')
            title           = $Title
            launcher        = $Launcher
            launcherArgs    = if ($LauncherArguments) { @($LauncherArguments) } else { @() }
        }

        # Side files left by an earlier agent in this tab describe another conversation.
        Remove-Item -LiteralPath (Join-Path $dir "$sessionId.state"), (Join-Path $dir "$sessionId.conv") -Force -ErrorAction SilentlyContinue
        Write-RegistryText (Join-Path $dir "$sessionId.json") ($record | ConvertTo-Json -Depth 4)
        return $sessionId
    } catch {
        return $null
    }
}

function Unregister-AgentSession {
    param([string]$SessionId = $env:WT_SESSION)
    try {
        if (-not (Test-SessionKey $SessionId)) { return }
        $dir = Get-SessionRegistryDir
        foreach ($extension in @('json', 'state', 'conv')) {
            Remove-Item -LiteralPath (Join-Path $dir "$SessionId.$extension") -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Remove-SessionSideFiles {
    # Everything the hooks and save-hwnd.exe keep for one tab outside the registry.
    param([string]$SessionId)
    try {
        if (-not (Test-SessionKey $SessionId)) { return }
        $notifyDir = Get-AgenticNotifyDir
        foreach ($name in @(".hwnd-$SessionId", ".tabindex-$SessionId", ".tabname-$SessionId", ".label-$SessionId",
                ".popup-$SessionId.pid", ".dismiss-$SessionId", ".cooldown-$SessionId", ".savehwnd-debug-$SessionId")) {
            Remove-Item -LiteralPath (Join-Path $notifyDir $name) -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Get-SessionConversation {
    # Only trust a conversation id the same agent reported: the user may have
    # quit the registered agent and started another one in the same tab.
    param($Record)
    $raw = Read-RegistryValue (Join-Path (Get-SessionRegistryDir) "$($Record.sessionId).conv")
    if (-not $raw) { return $null }
    $parts = $raw -split '\|', 2
    if ($parts.Count -eq 2 -and $parts[0] -eq [string]$Record.agent -and $parts[1] -match '^[A-Za-z0-9_.-]+$') { return $parts[1] }
    return $null
}

$script:ClosedSessionLimit = 30

function Save-ClosedSession {
    <#
    .SYNOPSIS
        Remember a tab that went away while its agent was still running.
    .DESCRIPTION
        A tab closed with its X button (or lost to a crash or reboot) never runs
        the launcher's cleanup, so its record is still there when its shell is
        found dead. `notify reopen` brings such a tab back. An agent the user
        quit unregisters itself and never gets here.
    #>
    param($Record)
    try {
        $closedDir = Join-Path (Get-SessionRegistryDir) 'closed'
        if (-not (Test-Path -LiteralPath $closedDir)) { $null = New-Item -ItemType Directory -Path $closedDir -Force }
        $closed = [ordered]@{
            sessionId    = [string]$Record.sessionId
            agent        = $Record.agent
            command      = $Record.command
            args         = @($Record.args)
            cwd          = $Record.cwd
            shell        = $Record.shell
            title        = $Record.title
            launcher     = $Record.launcher
            launcherArgs = @($Record.launcherArgs)
            conversation = Get-SessionConversation $Record
            startedUtc   = $Record.startedUtc
            closedUtc    = [DateTime]::UtcNow.ToString('o')
        }
        Write-RegistryText (Join-Path $closedDir "$($Record.sessionId).json") ($closed | ConvertTo-Json -Depth 4)
        Get-ChildItem -LiteralPath $closedDir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $script:ClosedSessionLimit | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-ClosedSessions {
    # Newest first. Each entry carries the file it came from in .path.
    $closedDir = Join-Path (Get-SessionRegistryDir) 'closed'
    $closed = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $closedDir)) { return $closed.ToArray() }
    foreach ($file in (Get-ChildItem -LiteralPath $closedDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $entry = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not $entry.command) { continue }
            $entry | Add-Member -NotePropertyName path -NotePropertyValue $file.FullName -Force
            $closed.Add($entry)
        } catch { }
    }
    return $closed.ToArray()
}

function Test-AgentSessionAlive {
    # The start time must match as well: Windows reuses process ids.
    param($Record)
    try {
        $process = Get-Process -Id ([int]$Record.shellPid) -ErrorAction SilentlyContinue
        if (-not $process) { return $false }
        return ($process.StartTime.ToUniversalTime().Ticks.ToString() -eq [string]$Record.shellStartTicks)
    } catch {
        return $false
    }
}

function Read-RegistryValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($text) { return $text.Trim() }
    return $null
}

function Get-AgentSessions {
    <#
    .SYNOPSIS
        Every registered tab whose shell is still running, with the hook-written
        state merged in. Records of dead shells move to the closed list on the way.
    #>
    $dir = Get-SessionRegistryDir
    $notifyDir = Get-AgenticNotifyDir
    $sessions = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $dir)) { return $sessions.ToArray() }

    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $record = $null
        try { $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { }
        if (-not $record -or -not (Test-SessionKey ([string]$record.sessionId))) {
            Unregister-AgentSession -SessionId $file.BaseName
            continue
        }
        if (-not (Test-AgentSessionAlive $record)) {
            # The record outlived its shell: the tab was closed under the agent.
            Save-ClosedSession $record
            Unregister-AgentSession -SessionId $file.BaseName
            Remove-SessionSideFiles -SessionId $file.BaseName
            continue
        }

        $sessionId = [string]$record.sessionId
        $state = Read-RegistryValue (Join-Path $dir "$sessionId.state")
        if (-not $state) { $state = 'idle' }
        $conversation = Get-SessionConversation $record

        $hwnd = [long]0
        $null = [long]::TryParse([string](Read-RegistryValue (Join-Path $notifyDir ".hwnd-$sessionId")), [ref]$hwnd)
        $tabIndex = 0
        $null = [int]::TryParse([string](Read-RegistryValue (Join-Path $notifyDir ".tabindex-$sessionId")), [ref]$tabIndex)

        $record | Add-Member -NotePropertyName state -NotePropertyValue $state -Force
        $record | Add-Member -NotePropertyName conversation -NotePropertyValue $conversation -Force
        $record | Add-Member -NotePropertyName hwnd -NotePropertyValue $hwnd -Force
        $record | Add-Member -NotePropertyName tabIndex -NotePropertyValue $tabIndex -Force
        $sessions.Add($record)
    }
    return $sessions.ToArray()
}

function Remove-SessionFlags {
    <#
    .SYNOPSIS
        Drop session-selecting flags from an argument list.
    .DESCRIPTION
        Matching is case-sensitive: Codex gives -c and -C different meanings.
        A flag written as --name=value carries its value with it.
    #>
    param(
        [string[]]$Arguments,
        [string[]]$Switches = @(),
        [string[]]$WithValue = @(),
        [string[]]$OptionalValue = @()
    )

    $kept = New-Object System.Collections.Generic.List[string]
    if (-not $Arguments) { return ,$kept.ToArray() }

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        $name = ($argument -split '=', 2)[0]
        $hasInlineValue = $argument.StartsWith('--') -and $argument.Contains('=')
        if ($Switches -ccontains $name) { continue }
        if ($WithValue -ccontains $name) {
            if (-not $hasInlineValue) { $i++ }
            continue
        }
        if ($OptionalValue -ccontains $name) {
            if (-not $hasInlineValue -and ($i + 1) -lt $Arguments.Count -and -not $Arguments[$i + 1].StartsWith('-')) { $i++ }
            continue
        }
        $kept.Add($argument)
    }
    return ,$kept.ToArray()
}

# Flags known to take no value. Only used to spot a start-up prompt below.
$script:AgentBooleanFlags = @(
    '--dangerously-skip-permissions', '--dangerously-bypass-approvals-and-sandbox',
    '--full-auto', '--yolo', '--verbose', '--debug', '--trust', '-f', '--force', '--search', '--oss'
)

function Remove-StartupPrompt {
    <#
    .SYNOPSIS
        Drop a prompt that was passed on the command line.
    .DESCRIPTION
        `claude "fix the build"` must not send "fix the build" a second time when
        the tab is restored. Without each CLI's full option table a prompt can
        only be guessed: the last argument, containing whitespace, not the value
        of a flag. A prompt after an unknown boolean flag is kept, so that case
        is replayed.
    #>
    param([string[]]$Arguments)

    if (-not $Arguments -or $Arguments.Count -eq 0) { return ,@() }
    $last = $Arguments[$Arguments.Count - 1]
    if ($last.StartsWith('-') -or $last -notmatch '\s') { return ,$Arguments }

    $isPrompt = $true
    if ($Arguments.Count -gt 1) {
        $previous = $Arguments[$Arguments.Count - 2]
        if ($previous.StartsWith('-') -and $script:AgentBooleanFlags -cnotcontains $previous) { $isPrompt = $false }
    }
    if (-not $isPrompt) { return ,$Arguments }
    if ($Arguments.Count -eq 1) { return ,@() }
    return ,@($Arguments[0..($Arguments.Count - 2)])
}

function Get-AgentResumeArguments {
    <#
    .SYNOPSIS
        Arguments that reopen one exact conversation with the flags the tab was
        started with.
    .DESCRIPTION
        Without a conversation id the original arguments are returned unchanged:
        nothing was said in that tab, so launching it the way the user did is the
        faithful restore.
    #>
    param(
        [string]$Agent,
        [string[]]$Arguments,
        [string]$ConversationId
    )

    if (-not $Arguments) { $Arguments = @() }
    if (-not $ConversationId) { return ,$Arguments }

    switch ($Agent) {
        'Claude' {
            $rest = Remove-SessionFlags -Arguments $Arguments -Switches '--continue', '-c', '--fork-session' `
                -WithValue '--session-id' -OptionalValue '--resume', '-r'
            $rest = Remove-StartupPrompt $rest
            return ,(@('--resume', $ConversationId) + $rest)
        }
        'Codex' {
            $rest = $Arguments
            if ($rest.Count -gt 0 -and $rest[0] -ceq 'resume') {
                $rest = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }
                # `resume <id>`: the id is the first bare token that looks like one.
                $withoutId = New-Object System.Collections.Generic.List[string]
                $dropped = $false
                foreach ($argument in $rest) {
                    if (-not $dropped -and $argument -match '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}$') { $dropped = $true; continue }
                    $withoutId.Add($argument)
                }
                $rest = $withoutId.ToArray()
            }
            $rest = Remove-SessionFlags -Arguments $rest -Switches '--last', '--all'
            # `codex resume` rejects -m, but takes the same setting as a config override.
            $converted = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $rest.Count; $i++) {
                if (($rest[$i] -ceq '-m' -or $rest[$i] -ceq '--model') -and ($i + 1) -lt $rest.Count) {
                    $converted.Add('-c'); $converted.Add("model=$($rest[$i + 1])"); $i++
                } elseif ($rest[$i].StartsWith('--model=')) {
                    $converted.Add('-c'); $converted.Add("model=$($rest[$i].Substring(8))")
                } else {
                    $converted.Add($rest[$i])
                }
            }
            $rest = Remove-StartupPrompt $converted.ToArray()
            return ,(@('resume', $ConversationId) + $rest)
        }
        'Pi' {
            $rest = Remove-SessionFlags -Arguments $Arguments -Switches '--continue', '-c', '--resume', '-r' `
                -WithValue '--session', '--session-id', '--fork'
            $rest = Remove-StartupPrompt $rest
            return ,(@('--session', $ConversationId) + $rest)
        }
        'Cursor' {
            $rest = $Arguments
            if ($rest.Count -gt 0 -and $rest[0] -ceq 'resume') {
                $rest = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }
            }
            $rest = Remove-SessionFlags -Arguments $rest -Switches '--continue' -OptionalValue '--resume'
            $rest = Remove-StartupPrompt $rest
            return ,(@('--resume', $ConversationId) + $rest)
        }
    }
    return ,$Arguments
}
