#Requires -Version 5.1
# Codex sends lifecycle JSON on stdin. Never return a blocking hook decision.
$ErrorActionPreference = 'Stop'
try {
    # Strip a leading BOM: a UTF-8 console code page adds one to piped input.
    $event = [Console]::In.ReadToEnd().TrimStart([char]0xFEFF) | ConvertFrom-Json
    # No shared "default" state outside Windows Terminal, and no shell/path
    # interpolation from untrusted hook payloads.
    if ($env:WT_SESSION -match '^[a-zA-Z0-9-]+$') {
        $action = switch ($event.hook_event_name) {
            'Stop' { 'attention' }
            'UserPromptSubmit' { 'resume' }
        }
        if ($action) {
            & (Join-Path $PSScriptRoot 'notify.ps1') -Action $action -Agent Codex *> $null
        }
    }
} catch {
    # Notification failures must not interfere with the conversation.
}
[Console]::Out.WriteLine('{}')
exit 0
