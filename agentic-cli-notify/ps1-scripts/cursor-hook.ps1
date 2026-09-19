#Requires -Version 5.1
# Cursor Agent CLI hook adapter.
#
# Cursor allows a different command per hook event, so the event is passed as an
# argument instead of being parsed out of the stdin payload. That avoids relying
# on the payload field name, which differs between Cursor versions
# (hook_event_name vs hookEventName).
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('attention', 'resume')]
    [string]$Action
)
$ErrorActionPreference = 'Stop'
try {
    # Drain stdin so Cursor never blocks on an unread pipe.
    $null = [Console]::In.ReadToEnd()
    # No shared "default" state outside Windows Terminal.
    if ($env:WT_SESSION -match '^[a-zA-Z0-9-]+$') {
        & (Join-Path $PSScriptRoot 'notify.ps1') -Action $Action -Agent Cursor *> $null
    }
} catch {
    # Notification failures must not interfere with the conversation.
}
if ($Action -eq 'resume') {
    [Console]::Out.WriteLine('{"continue": true}')
} else {
    [Console]::Out.WriteLine('{}')
}
exit 0
