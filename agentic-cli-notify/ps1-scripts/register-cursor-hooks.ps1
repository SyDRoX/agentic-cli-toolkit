#Requires -Version 5.1
param(
    [string]$CursorDir = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$NotifyDir = (Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify')
)
$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $CursorDir 'hooks.json'
$hookPath = Join-Path ([IO.Path]::GetFullPath($NotifyDir)) 'cursor-hook.ps1'
if (-not (Test-Path -LiteralPath $hookPath)) { throw "Hook not installed: $hookPath" }

# Cursor event -> notify action. "stop" fires when the agent finishes its turn,
# "beforeSubmitPrompt" when the user sends the next prompt.
$eventActions = [ordered]@{
    'stop'               = 'attention'
    'beforeSubmitPrompt' = 'resume'
}

$settings = if (Test-Path -LiteralPath $settingsPath) {
    Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else { [PSCustomObject]@{} }
if ($settings -isnot [PSCustomObject]) { throw 'hooks.json must contain a JSON object.' }
if (-not $settings.PSObject.Properties['version']) {
    $settings | Add-Member -NotePropertyName version -NotePropertyValue 1
}
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
}
if ($settings.hooks -isnot [PSCustomObject]) { throw 'hooks must be a JSON object.' }

$changed = $false
foreach ($eventName in $eventActions.Keys) {
    $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hookPath + '" -Action ' + $eventActions[$eventName]
    $entries = @()
    if ($settings.hooks.PSObject.Properties[$eventName]) {
        if ($settings.hooks.$eventName -isnot [array]) { throw "$eventName must be an array." }
        $entries = @($settings.hooks.$eventName)
    }
    $found = $false
    foreach ($entry in $entries) {
        if ($entry.command -eq $command) { $found = $true }
    }
    if (-not $found) {
        $entries += [PSCustomObject]@{ command = $command }
        $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue $entries -Force
        $changed = $true
    }
}

if ($changed) {
    $json = $settings | ConvertTo-Json -Depth 100
    $null = $json | ConvertFrom-Json
    $null = New-Item -ItemType Directory -Path $CursorDir -Force
    if (Test-Path -LiteralPath $settingsPath) {
        $backup = "$settingsPath.bak-agentic-cli-notify-$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $settingsPath -Destination $backup
        Write-Host "Backup: $backup"
    }
    [IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host "Cursor hooks registered: $settingsPath"
} else {
    Write-Host 'Cursor hooks already registered; nothing changed.'
}
