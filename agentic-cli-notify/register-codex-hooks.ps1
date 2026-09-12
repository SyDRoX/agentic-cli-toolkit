#Requires -Version 5.1
param(
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$NotifyDir = (Join-Path $env:USERPROFILE '.claude\hooks\claude-notify')
)
$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $CodexDir 'hooks.json'
$hookPath = Join-Path ([IO.Path]::GetFullPath($NotifyDir)) 'codex-hook.ps1'
if (-not (Test-Path -LiteralPath $hookPath)) { throw "Hook not installed: $hookPath" }
$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hookPath + '"'
$settings = if (Test-Path -LiteralPath $settingsPath) {
    Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
} else { [PSCustomObject]@{} }
if ($settings -isnot [PSCustomObject]) { throw 'hooks.json must contain a JSON object.' }
if (-not $settings.PSObject.Properties['hooks']) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
}
if ($settings.hooks -isnot [PSCustomObject]) { throw 'hooks must be a JSON object.' }
$changed = $false
foreach ($eventName in @('Stop', 'UserPromptSubmit')) {
    $entries = @()
    if ($settings.hooks.PSObject.Properties[$eventName]) {
        if ($settings.hooks.$eventName -isnot [array]) { throw "$eventName must be an array." }
        $entries = @($settings.hooks.$eventName)
    }
    $found = $false
    foreach ($entry in $entries) {
        foreach ($handler in $entry.hooks) {
            if ($handler.command -eq $command) { $found = $true }
        }
    }
    if (-not $found) {
        $entries += [PSCustomObject]@{ hooks = @([PSCustomObject]@{
            type = 'command'; command = $command; timeout = 10
        }) }
        $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue $entries -Force
        $changed = $true
    }
}
if ($changed) {
    $json = $settings | ConvertTo-Json -Depth 100
    $null = $json | ConvertFrom-Json
    $null = New-Item -ItemType Directory -Path $CodexDir -Force
    if (Test-Path -LiteralPath $settingsPath) {
        $backup = "$settingsPath.bak-claude-notify-$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $settingsPath -Destination $backup
        Write-Host "Backup: $backup"
    }
    [IO.File]::WriteAllText($settingsPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host "Codex hooks registered: $settingsPath"
} else {
    Write-Host 'Codex hooks already registered; nothing changed.'
}
