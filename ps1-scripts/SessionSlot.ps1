# Shared session-slot helpers. Dot-sourced by launch-claude.ps1 and
# Test-Resume.ps1 so the launcher and the dry-run tester can never disagree
# about which conversation a tab should reopen.

function Get-SlotSessionId {
    <#
    .SYNOPSIS
        Deterministic RFC-4122 v3 (MD5, name-based) UUID for a (window, tab) slot.
    .DESCRIPTION
        The same slot always yields the same UUID, so a tab maps to the same
        conversation across relaunches with no state file involved.

        Built by formatting the MD5 bytes as a string in RFC order rather than
        via [guid]::new([byte[]]). That constructor reads the first three fields
        LITTLE-ENDIAN, so a byte-array UUID comes out with its bytes swapped
        within the first three groups - which is why upstream's
        `$hash[6] = ... -bor 0x30` lands the version nibble on the wrong nibble
        and emits ids like "...-a13f-..." and "...-0337-...". Claude Code's
        --session-id validation is lenient enough to accept those today, but
        they are not well-formed UUIDs.
    #>
    param(
        [Parameter(Mandatory = $true)] $WindowNum,
        [Parameter(Mandatory = $true)] $TabIndex
    )

    $slotKey = "devlayout-w$WindowNum-t$TabIndex"

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($slotKey))
    } finally {
        $md5.Dispose()
    }

    # RFC 4122: version 3 in the high nibble of byte 6, variant 0b10xx in the
    # high bits of byte 8. Correct because we format big-endian below.
    $hash[6] = [byte](($hash[6] -band 0x0F) -bor 0x30)
    $hash[8] = [byte](($hash[8] -band 0x3F) -bor 0x80)

    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })

    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8),
                                    $hex.Substring(8, 4),
                                    $hex.Substring(12, 4),
                                    $hex.Substring(16, 4),
                                    $hex.Substring(20, 12)
}

function Get-SlotProjectPath {
    <#
    .SYNOPSIS
        The ~/.claude/projects directory Claude Code uses for a working directory.
    .DESCRIPTION
        Claude Code derives the directory name by replacing ":" and "\" with "-",
        e.g. C:\Repos\ormi-unity -> C--Repos-ormi-unity. TrimEnd guards against a
        trailing separator producing a trailing "-" that would miss the real dir.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDir
    )

    $projectDir = $WorkingDir.TrimEnd('\') -replace '[:\\]', '-'
    return (Join-Path $env:USERPROFILE ".claude\projects\$projectDir")
}

function Resolve-SlotResume {
    <#
    .SYNOPSIS
        Decide which session id a slot should resume, if any.
    .DESCRIPTION
        Priority: state file (a manual /resume the SessionStart hook recorded)
        > deterministic slot UUID > nothing (start fresh).

        A candidate only counts if its transcript actually exists in THIS repo's
        project directory, so a stale state file cannot send a tab chasing a
        conversation that belongs to another repo or was deleted.
    .OUTPUTS
        Hashtable: ResumeId, Source, DefaultSessionId, ProjectPath, StateFile
    #>
    param(
        [Parameter(Mandatory = $true)] $WindowNum,
        [Parameter(Mandatory = $true)] $TabIndex,
        [Parameter(Mandatory = $true)][string]$WorkingDir,
        [Parameter(Mandatory = $true)][string]$StateDir
    )

    $defaultSessionId = Get-SlotSessionId -WindowNum $WindowNum -TabIndex $TabIndex
    $projectPath      = Get-SlotProjectPath -WorkingDir $WorkingDir
    $stateFile        = Join-Path $StateDir ".devlayout-session-w$WindowNum-t$TabIndex"

    $resumeId = $null
    $source   = $null
    $stateRaw = $null

    if (Test-Path $stateFile) {
        $stateRaw = (Get-Content $stateFile -Raw -ErrorAction SilentlyContinue)
        if ($stateRaw) { $stateRaw = $stateRaw.Trim() }
        if ($stateRaw -and (Test-Path (Join-Path $projectPath "$stateRaw.jsonl"))) {
            $resumeId = $stateRaw
            $source   = 'state file (manual /resume)'
        }
    }

    if (-not $resumeId -and (Test-Path (Join-Path $projectPath "$defaultSessionId.jsonl"))) {
        $resumeId = $defaultSessionId
        $source   = 'deterministic slot UUID'
    }

    return @{
        ResumeId         = $resumeId
        Source           = $source
        DefaultSessionId = $defaultSessionId
        ProjectPath      = $projectPath
        StateFile        = $stateFile
        StateRaw         = $stateRaw
    }
}
