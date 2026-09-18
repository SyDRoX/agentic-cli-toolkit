[CmdletBinding()]
param(
    [ValidateSet("New", "Append")]
    [string]$Mode,

    [ValidateSet("Standard", "Admin")]
    [string]$Elevation,

    [string]$ConfigPath = (Join-Path $PSScriptRoot "LLM_ContextMenu.config.yaml"),

    # These two parameters are used by the installed context-menu commands.
    [string]$LaunchModel,
    [string]$WorkingDirectory
)

$ErrorActionPreference = "Stop"

function Remove-YamlComment {
    param([string]$Text)

    $quote = [char]0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if (($character -eq "'") -or ($character -eq '"')) {
            if ($quote -eq [char]0) {
                $quote = $character
            } elseif ($quote -eq $character) {
                # YAML escapes a single quote inside a single-quoted scalar by doubling it.
                if (($quote -eq "'") -and ($i + 1 -lt $Text.Length) -and ($Text[$i + 1] -eq "'")) {
                    $i++
                } else {
                    $quote = [char]0
                }
            }
        } elseif (($character -eq '#') -and ($quote -eq [char]0)) {
            return $Text.Substring(0, $i).TrimEnd()
        }
    }

    return $Text.TrimEnd()
}

function ConvertFrom-YamlScalar {
    param([string]$Value)

    $Value = $Value.Trim()
    if ($Value -match "^'(.*)'$") {
        return $Matches[1].Replace("''", "'")
    }
    if ($Value -match '^".*"$') {
        return ($Value | ConvertFrom-Json)
    }
    if ($Value -match '^(?i:true|false)$') {
        return [bool]::Parse($Value)
    }
    if ($Value -match '^(?i:null|~)$') {
        return $null
    }
    return $Value
}

function Import-LLMMenuConfig {
    param([string]$Path)

    $config = [ordered]@{
        Menu = [ordered]@{ Title = "Open LLM CLI here" }
        Models = @(
            [pscustomobject]@{ Id = "AntiGravity"; Label = "Anti Gravity"; Command = "agy --dangerously-skip-permissions" }
            [pscustomobject]@{ Id = "Claude"; Label = "Claude"; Command = "claude --dangerously-skip-permissions" }
            [pscustomobject]@{ Id = "Codex"; Label = "Codex"; Command = "codex --dangerously-bypass-approvals-and-sandbox" }
            [pscustomobject]@{ Id = "PiGpt56Luna"; Label = "Pi - GPT 5.6 Luna (medium, 256K)"; Command = "pi --model gpt-5.6-luna:medium" }
            [pscustomobject]@{ Id = "Agent"; Label = "Agent"; Command = "agent -f" }
        )
        Toggles = [ordered]@{ TerminalMode = $true; Elevation = $true }
        Defaults = [ordered]@{ TerminalMode = "New"; Elevation = "Standard" }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Config file not found at '$Path'; using built-in defaults."
        return $config
    }

    # This deliberately supports the small, dependency-free YAML subset used by
    # LLM_ContextMenu.config.yaml: top-level mappings and a list of model mappings.
    $section = $null
    $models = [System.Collections.Generic.List[object]]::new()
    $currentModel = $null
    $lineNumber = 0

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = Remove-YamlComment $rawLine
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^([A-Za-z][A-Za-z0-9]*):\s*$') {
            $section = $Matches[1].ToLowerInvariant()
            if ($section -notin @("menu", "models", "toggles", "defaults")) {
                throw "Unsupported YAML section '$($Matches[1])' at $Path`:$lineNumber."
            }
            continue
        }

        if ($section -eq "models") {
            if ($line -match '^\s{2}-\s+([A-Za-z][A-Za-z0-9]*):\s*(.*)$') {
                if ($null -ne $currentModel) { $models.Add([pscustomobject]$currentModel) }
                $currentModel = [ordered]@{}
                $currentModel[$Matches[1]] = ConvertFrom-YamlScalar $Matches[2]
                continue
            }
            if (($null -ne $currentModel) -and ($line -match '^\s{4}([A-Za-z][A-Za-z0-9]*):\s*(.*)$')) {
                $currentModel[$Matches[1]] = ConvertFrom-YamlScalar $Matches[2]
                continue
            }
        } elseif ($line -match '^\s{2}([A-Za-z][A-Za-z0-9]*):\s*(.*)$') {
            $key = $Matches[1]
            $value = ConvertFrom-YamlScalar $Matches[2]
            switch ($section) {
                "menu" { $config.Menu[$key] = $value }
                "toggles" { $config.Toggles[$key] = $value }
                "defaults" { $config.Defaults[$key] = $value }
                default { throw "A value was found before a supported section at $Path`:$lineNumber." }
            }
            continue
        }

        throw "Unsupported YAML syntax at $Path`:${lineNumber}: $rawLine"
    }

    if ($null -ne $currentModel) { $models.Add([pscustomobject]$currentModel) }
    if ($models.Count -gt 0) { $config.Models = $models.ToArray() }

    $seenIds = @{}
    foreach ($model in $config.Models) {
        if (-not $model.Id -or $model.Id -notmatch '^[A-Za-z0-9_-]+$') {
            throw "Every model id must contain only letters, numbers, underscores, or hyphens. Invalid id: '$($model.Id)'."
        }
        if (-not $model.Label -or -not $model.Command) {
            throw "Model '$($model.Id)' must have both label and command values."
        }
        if ($seenIds.ContainsKey($model.Id)) { throw "Duplicate model id '$($model.Id)' in '$Path'." }
        $seenIds[$model.Id] = $true
    }

    if ($config.Defaults.TerminalMode -notin @("New", "Append")) {
        throw "defaults.terminalMode must be New or Append."
    }
    if ($config.Defaults.Elevation -notin @("Standard", "Admin")) {
        throw "defaults.elevation must be Standard or Admin."
    }
    if (($config.Toggles.TerminalMode -isnot [bool]) -or ($config.Toggles.Elevation -isnot [bool])) {
        throw "toggles.terminalMode and toggles.elevation must be true or false."
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.Menu.Title)) {
        throw "menu.title cannot be empty."
    }

    return $config
}

function Quote-CommandArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function New-RadioMarkerIcon {
    param([string]$Path)

    Add-Type -AssemblyName System.Drawing
    $personalizePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    $theme = Get-ItemProperty -LiteralPath $personalizePath -ErrorAction SilentlyContinue
    $isLightTheme = ($null -eq $theme) -or ($theme.AppsUseLightTheme -ne 0)
    $markerColor = if ($isLightTheme) {
        [Drawing.Color]::FromArgb(255, 32, 32, 32)
    } else {
        [Drawing.Color]::FromArgb(255, 245, 245, 245)
    }

    $iconDirectory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $iconDirectory)) {
        New-Item -ItemType Directory -Path $iconDirectory -Force | Out-Null
    }

    $bitmap = [Drawing.Bitmap]::new(16, 16, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brush = [Drawing.SolidBrush]::new($markerColor)
    $fileStream = $null
    $writer = $null
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.FillEllipse($brush, 5, 5, 6, 6)

        # Write a classic 32-bit ICO with both alpha and an AND transparency
        # mask. Bitmap.GetHicon() flattens transparency, while PNG-backed ICOs
        # cannot be decoded by the .NET Framework version used by PowerShell 5.1.
        $width = 16
        $height = 16
        $xorSize = $width * $height * 4
        $maskStride = [int]([Math]::Ceiling($width / 32.0) * 4)
        $maskSize = $maskStride * $height
        $imageSize = 40 + $xorSize + $maskSize

        $fileStream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.BinaryWriter]::new($fileStream)
        $writer.Write([uint16]0)                  # Reserved
        $writer.Write([uint16]1)                  # ICO image type
        $writer.Write([uint16]1)                  # Image count
        $writer.Write([byte]16)                   # Width
        $writer.Write([byte]16)                   # Height
        $writer.Write([byte]0)                    # Palette size
        $writer.Write([byte]0)                    # Reserved
        $writer.Write([uint16]1)                  # Color planes
        $writer.Write([uint16]32)                 # Bits per pixel
        $writer.Write([uint32]$imageSize)         # Payload size
        $writer.Write([uint32]22)                 # Payload offset

        $writer.Write([uint32]40)                 # BITMAPINFOHEADER size
        $writer.Write([int32]$width)
        $writer.Write([int32]($height * 2))        # XOR image + AND mask
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]0)                  # BI_RGB
        $writer.Write([uint32]$xorSize)
        $writer.Write([int32]0)                   # Horizontal resolution
        $writer.Write([int32]0)                   # Vertical resolution
        $writer.Write([uint32]0)                  # Palette colors
        $writer.Write([uint32]0)                  # Important colors

        # ICO bitmap rows are stored bottom-up in BGRA order.
        for ($y = $height - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $width; $x++) {
                $pixel = $bitmap.GetPixel($x, $y)
                $writer.Write([byte]$pixel.B)
                $writer.Write([byte]$pixel.G)
                $writer.Write([byte]$pixel.R)
                $writer.Write([byte]$pixel.A)
            }
        }

        for ($y = $height - 1; $y -ge 0; $y--) {
            $maskRow = [byte[]]::new($maskStride)
            for ($x = 0; $x -lt $width; $x++) {
                if ($bitmap.GetPixel($x, $y).A -eq 0) {
                    $byteIndex = [int][Math]::Floor($x / 8)
                    $maskRow[$byteIndex] = [byte]($maskRow[$byteIndex] -bor (0x80 -shr ($x % 8)))
                }
            }
            $writer.Write($maskRow)
        }
    } finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        } elseif ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

# Run notification setup inside the new tab so it inherits that tab's WT_SESSION.
# Use Git Bash explicitly: bash.exe on PATH may be the WSL launcher.
$setupSnippet = @'
$notifySetup = Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify\setup.sh'
$gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
if ((Test-Path -LiteralPath $notifySetup) -and (Test-Path -LiteralPath $gitBash)) {
    & $gitBash $notifySetup
} else {
    Write-Warning 'Notification setup skipped: install agentic-cli-notify and Git for Windows.'
}
'@

function Start-LLMTerminal {
    param(
        [string]$LaunchCommand,
        [string]$Directory,
        [ValidateSet("New", "Append")]
        [string]$TerminalMode,
        [ValidateSet("Standard", "Admin")]
        [string]$RunAs
    )

    $script = $setupSnippet + [Environment]::NewLine + $LaunchCommand
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $windowArguments = if ($TerminalMode -eq "Append") { "-w 0" } else { "-w -1" }
    $arguments = "$windowArguments -d $(Quote-CommandArgument $Directory) powershell.exe -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded"

    $startParameters = @{
        FilePath = "wt.exe"
        ArgumentList = $arguments
    }
    if ($RunAs -eq "Admin") { $startParameters.Verb = "RunAs" }
    Start-Process @startParameters
}

$config = Import-LLMMenuConfig $ConfigPath
if (-not $Mode) { $Mode = $config.Defaults.TerminalMode }
if (-not $Elevation) { $Elevation = $config.Defaults.Elevation }

if ($LaunchModel) {
    if (-not $WorkingDirectory) { throw "WorkingDirectory is required when LaunchModel is used." }
    $model = $config.Models | Where-Object { $_.Id -eq $LaunchModel } | Select-Object -First 1
    if (-not $model) { throw "Model '$LaunchModel' was not found in '$ConfigPath'. Re-run the installer after changing model ids." }
    Start-LLMTerminal -LaunchCommand $model.Command -Directory $WorkingDirectory -TerminalMode $Mode -RunAs $Elevation
    return
}

$basePaths = @(
    "HKCU:\Software\Classes\Directory\shell\OpenLLM",
    "HKCU:\Software\Classes\Directory\Background\shell\OpenLLM"
)

$wtPackage = Get-AppxPackage Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
$iconPath = "powershell.exe"
if ($wtPackage -and $wtPackage.InstallLocation) {
    $realWtExe = Join-Path $wtPackage.InstallLocation "wt.exe"
    if (Test-Path -LiteralPath $realWtExe) { $iconPath = $realWtExe }
}

$scriptPath = $PSCommandPath
$resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$commonArguments = "-ConfigPath $(Quote-CommandArgument $resolvedConfigPath) -Mode $Mode -Elevation $Elevation"
$radioIconPath = Join-Path $env:LOCALAPPDATA "agentic-cli-toolkit\context-menu-radio-transparent.ico"
New-RadioMarkerIcon $radioIconPath

foreach ($base in $basePaths) {
    if (-not (Test-Path -LiteralPath $base)) { New-Item -Path $base -Force | Out-Null }
    Set-ItemProperty -Path $base -Name "MUIVerb" -Value $config.Menu.Title
    Set-ItemProperty -Path $base -Name "SubCommands" -Value ""
    Set-ItemProperty -Path $base -Name "Icon" -Value $iconPath

    # Rebuild only this menu's children so removed/reordered YAML entries do not linger.
    $shellPath = "$base\shell"
    Remove-Item -LiteralPath $shellPath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $shellPath -Force | Out-Null

    $position = 0
    foreach ($model in $config.Models) {
        $position++
        $modelPath = Join-Path $shellPath (("{0:D2}_{1}" -f $position, $model.Id))
        New-Item -Path $modelPath -Force -Value $model.Label | Out-Null
        Set-ItemProperty -Path $modelPath -Name "Icon" -Value $iconPath

        $launchArguments = "$commonArguments -LaunchModel $($model.Id) -WorkingDirectory `"%V.`""
        $launchCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath) $launchArguments"
        New-Item -Path "$modelPath\command" -Force -Value $launchCommand | Out-Null
    }

    if ([bool]$config.Toggles.TerminalMode) {
        $position++
        $newTermPath = Join-Path $shellPath (("{0:D2}_NewTerm" -f $position))
        New-Item -Path $newTermPath -Force -Value "New terminal" | Out-Null
        Set-ItemProperty -Path $newTermPath -Name "CommandFlags" -Value 32 -Type DWord
        if ($Mode -eq "New") { Set-ItemProperty -Path $newTermPath -Name "Icon" -Value $radioIconPath }

        $position++
        $appendTermPath = Join-Path $shellPath (("{0:D2}_AppendTerm" -f $position))
        New-Item -Path $appendTermPath -Force -Value "Append to existing terminal" | Out-Null
        if ($Mode -eq "Append") { Set-ItemProperty -Path $appendTermPath -Name "Icon" -Value $radioIconPath }

        $newToggleArguments = "-ConfigPath $(Quote-CommandArgument $resolvedConfigPath) -Mode New -Elevation $Elevation"
        $appendToggleArguments = "-ConfigPath $(Quote-CommandArgument $resolvedConfigPath) -Mode Append -Elevation $Elevation"
        New-Item -Path "$newTermPath\command" -Force -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath) $newToggleArguments" | Out-Null
        New-Item -Path "$appendTermPath\command" -Force -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath) $appendToggleArguments" | Out-Null
    }

    if ([bool]$config.Toggles.Elevation) {
        $position++
        $standardPath = Join-Path $shellPath (("{0:D2}_Standard" -f $position))
        New-Item -Path $standardPath -Force -Value "Standard terminal" | Out-Null
        Set-ItemProperty -Path $standardPath -Name "CommandFlags" -Value 32 -Type DWord
        if ($Elevation -eq "Standard") { Set-ItemProperty -Path $standardPath -Name "Icon" -Value $radioIconPath }

        $position++
        $adminPath = Join-Path $shellPath (("{0:D2}_Admin" -f $position))
        New-Item -Path $adminPath -Force -Value "Administrator terminal" | Out-Null
        if ($Elevation -eq "Admin") { Set-ItemProperty -Path $adminPath -Name "Icon" -Value $radioIconPath }

        $standardArguments = "-ConfigPath $(Quote-CommandArgument $resolvedConfigPath) -Mode $Mode -Elevation Standard"
        $adminArguments = "-ConfigPath $(Quote-CommandArgument $resolvedConfigPath) -Mode $Mode -Elevation Admin"
        New-Item -Path "$standardPath\command" -Force -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath) $standardArguments" | Out-Null
        New-Item -Path "$adminPath\command" -Force -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $(Quote-CommandArgument $scriptPath) $adminArguments" | Out-Null
    }
}

Write-Host "Installed '$($config.Menu.Title)' with $($config.Models.Count) CLI option(s): mode=$Mode, elevation=$Elevation."
