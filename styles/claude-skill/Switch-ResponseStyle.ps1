#Requires -Version 5.1
<#
.SYNOPSIS
    Switches the Claude Code response style. Run by the /style skill.
.DESCRIPTION
    Sets outputStyle in settings.json so new sessions start in the style, records the
    choice for the statusline, and prints the rules so the running session can adopt
    them. Installed beside styles.json by Install-ResponseStyles.ps1.
.PARAMETER Style
    A catalog key or label, "toggle" (default) for the next style, or "status".
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Style = "toggle",
    [Parameter(Position = 1)][string]$SessionId = "",
    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),
    [string]$CavemanConfigDir = (Join-Path $env:APPDATA "caveman")
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$catalogPath = Join-Path $PSScriptRoot "styles.json"
$catalogJson = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
$styles = @()
foreach ($prop in $catalogJson.PSObject.Properties) {
    $styles += @{ Key = $prop.Name.ToLowerInvariant(); Label = [string]$prop.Value.label; File = [string]$prop.Value.file }
}
if ($styles.Count -eq 0) { throw "No styles in $catalogPath" }

$settingsPath = Join-Path $ClaudeDir "settings.json"
$modePath = Join-Path $ClaudeDir ".style-mode"

function Find-Style([string]$Name) {
    $wanted = $Name.Trim().ToLowerInvariant()
    foreach ($candidate in $styles) {
        if ($candidate.Key -eq $wanted -or $candidate.Label.ToLowerInvariant() -eq $wanted) { return $candidate }
    }
    return $null
}

function Get-CurrentStyle {
    if (Test-Path -LiteralPath $modePath) {
        $found = Find-Style ([System.IO.File]::ReadAllText($modePath))
        if ($found) { return $found }
    }
    if (Test-Path -LiteralPath $settingsPath) {
        $text = [System.IO.File]::ReadAllText($settingsPath)
        if ($text -match '"outputStyle"\s*:\s*"([^"]*)"') {
            $found = Find-Style $Matches[1]
            if ($found) { return $found }
        }
    }
    return $null
}

function Set-OutputStyle([string]$Label) {
    # Text edit, not a ConvertTo-Json round trip: 5.1 would reformat the whole file.
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        [System.IO.File]::WriteAllText($settingsPath, "{`n  `"outputStyle`": `"$Label`"`n}`n", $utf8NoBom)
        return
    }

    $text = [System.IO.File]::ReadAllText($settingsPath)
    $pattern = [regex]'("outputStyle"\s*:\s*)"[^"]*"'
    if ($pattern.IsMatch($text)) {
        $updated = $pattern.Replace($text, { param($m) $m.Groups[1].Value + '"' + $Label + '"' }, 1)
    } else {
        $brace = $text.IndexOf('{')
        if ($brace -lt 0) { throw "settings.json has no JSON object: $settingsPath" }
        $rest = $text.Substring($brace + 1)
        $separator = if ($rest.Trim() -eq '}') { '' } else { ',' }
        $updated = $text.Substring(0, $brace + 1) + "`n  `"outputStyle`": `"$Label`"$separator" + $rest
    }

    $null = $updated | ConvertFrom-Json
    [System.IO.File]::WriteAllText($settingsPath, $updated, $utf8NoBom)
}

function Set-CavemanPluginMode([string]$Mode) {
    # Only for users of the caveman plugin: its SessionStart hook injects caveman
    # rules into every new session unless its default mode is "off".
    $flagPath = Join-Path $ClaudeDir ".caveman-active"
    $configPath = Join-Path $CavemanConfigDir "config.json"
    $pluginCache = Join-Path $ClaudeDir "plugins\cache\caveman"
    $isPluginUser = (Test-Path -LiteralPath $configPath) -or (Test-Path -LiteralPath $flagPath) -or (Test-Path -LiteralPath $pluginCache)
    if (-not $isPluginUser) { return }

    if (-not (Test-Path -LiteralPath $CavemanConfigDir)) {
        New-Item -ItemType Directory -Path $CavemanConfigDir -Force | Out-Null
    }
    $config = $null
    if (Test-Path -LiteralPath $configPath) {
        try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $config = $null }
    }
    if ($null -eq $config) { $config = New-Object PSObject }
    $config | Add-Member -MemberType NoteProperty -Name defaultMode -Value $Mode -Force
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)

    if ($Mode -eq "off") {
        Remove-Item -LiteralPath $flagPath -ErrorAction SilentlyContinue
    } else {
        [System.IO.File]::WriteAllText($flagPath, $Mode, $utf8NoBom)
    }
}

function Get-Rules($Entry) {
    $path = Join-Path (Join-Path $ClaudeDir "output-styles") $Entry.File
    if (-not (Test-Path -LiteralPath $path)) { throw "Output style file missing: $path. Run Install-ResponseStyles.ps1 again." }
    $text = [System.IO.File]::ReadAllText($path)
    return ([regex]'(?s)\A---.*?---\s*').Replace($text, '', 1).Trim()
}

$current = Get-CurrentStyle
$wanted = $Style.Trim().ToLowerInvariant()

if ($wanted -eq "status") {
    if ($current) { Write-Output "style: $($current.Key) ($($current.Label))" } else { Write-Output "style: none of the toolkit styles is active" }
    return
}

if ($wanted -eq "" -or $wanted -eq "toggle") {
    $index = -1
    if ($current) {
        for ($i = 0; $i -lt $styles.Count; $i++) { if ($styles[$i].Key -eq $current.Key) { $index = $i } }
    }
    $target = $styles[($index + 1) % $styles.Count]
} else {
    $target = Find-Style $wanted
    if (-not $target) {
        $known = ($styles | ForEach-Object { $_.Key }) -join " | "
        Write-Output "unknown style '$Style'. Use: $known | toggle | status"
        exit 2
    }
}

$rules = Get-Rules $target
Set-OutputStyle $target.Label
Set-CavemanPluginMode $(if ($target.Key -eq "caveman") { "full" } else { "off" })
[System.IO.File]::WriteAllText($modePath, $target.Key, $utf8NoBom)

if ($SessionId -match '^[A-Za-z0-9_-]+$') {
    $sessionsDir = Join-Path $ClaudeDir "style-sessions"
    if (-not (Test-Path -LiteralPath $sessionsDir)) { New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $sessionsDir $SessionId), $target.Key, $utf8NoBom)
}

$previous = if ($current) { $current.Label } else { "none" }
Write-Output "STYLE SWITCHED: $($target.Label) (was $previous)"
Write-Output "Use the rules below from the next response on. They replace the previous response style."
Write-Output ""
Write-Output $rules
