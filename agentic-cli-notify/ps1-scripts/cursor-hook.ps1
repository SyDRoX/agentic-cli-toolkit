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
    $payload = [Console]::In.ReadToEnd()
    # No shared "default" state outside Windows Terminal.
    if ($env:WT_SESSION -match '^[a-zA-Z0-9-]+$') {
        # The chat id lets `notify restore` reopen this exact chat. Best effort:
        # the payload is only parsed for this, never for the event name.
        $notifyArguments = @{ Action = $Action; Agent = 'Cursor' }
        try {
            $hookPayload = $payload.TrimStart([char]0xFEFF) | ConvertFrom-Json
            foreach ($field in @('conversation_id', 'conversationId', 'session_id')) {
                if ([string]$hookPayload.$field -match '^[A-Za-z0-9-]+$') { $notifyArguments.ConversationId = [string]$hookPayload.$field; break }
            }
        } catch { }
        & (Join-Path $PSScriptRoot 'notify.ps1') @notifyArguments *> $null
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
