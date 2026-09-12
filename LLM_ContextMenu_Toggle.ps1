param(
    [ValidateSet("New", "Append")]
    [string]$Mode = "New"
)

$basePaths = @(
    "HKCU:\Software\Classes\Directory\shell\OpenLLM",
    "HKCU:\Software\Classes\Directory\Background\shell\OpenLLM"
)

# Run setup inside the new tab so it inherits that tab's WT_SESSION.
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

function New-LLMTerminalCommand {
    param([string]$TerminalPrefix, [string]$LaunchCommand)
    # WT interprets semicolons as tab separators even inside quoted commands.
    # Encoding keeps setup and launch together in the same PowerShell process.
    $script = $setupSnippet + [Environment]::NewLine + $LaunchCommand
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return "$TerminalPrefix -d `"%V.`" powershell.exe -ExecutionPolicy Bypass -NoExit -EncodedCommand $encoded"
}

$wtPackage = Get-AppxPackage Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
$iconPath = "powershell.exe"
if ($wtPackage -and $wtPackage.InstallLocation) {
    $realWtExe = Join-Path $wtPackage.InstallLocation "wt.exe"
    if (Test-Path $realWtExe) { $iconPath = $realWtExe }
}

foreach ($base in $basePaths) {
    if (-not (Test-Path $base)) { New-Item -Path $base -Force | Out-Null }
    Set-ItemProperty -Path $base -Name "MUIVerb" -Value "Open LLM CLI here"
    Set-ItemProperty -Path $base -Name "SubCommands" -Value ""
    Set-ItemProperty -Path $base -Name "Icon" -Value $iconPath

    Remove-Item "$base\shell\AntiGravity" -Recurse -ErrorAction SilentlyContinue
    Remove-Item "$base\shell\Claude" -Recurse -ErrorAction SilentlyContinue
    Remove-Item "$base\shell\Codex" -Recurse -ErrorAction SilentlyContinue
    Remove-Item "$base\shell\04_NewTerm" -Recurse -ErrorAction SilentlyContinue
    Remove-Item "$base\shell\05_AppendTerm" -Recurse -ErrorAction SilentlyContinue

    $agPath = "$base\shell\01_AntiGravity"
    New-Item -Path $agPath -Force -Value "Anti Gravity" | Out-Null
    Set-ItemProperty -Path $agPath -Name "Icon" -Value $iconPath

    $claudePath = "$base\shell\02_Claude"
    New-Item -Path $claudePath -Force -Value "Claude" | Out-Null
    Set-ItemProperty -Path $claudePath -Name "Icon" -Value $iconPath

    $codexPath = "$base\shell\03_Codex"
    New-Item -Path $codexPath -Force -Value "Codex" | Out-Null
    Set-ItemProperty -Path $codexPath -Name "Icon" -Value $iconPath

    $piPath = "$base\shell\04_PiHy4"
    New-Item -Path $piPath -Force -Value "Pi HY4[256K]" | Out-Null
    Set-ItemProperty -Path $piPath -Name "Icon" -Value $iconPath

    $agentPath = "$base\shell\05_Agent"
    New-Item -Path $agentPath -Force -Value "Agent" | Out-Null
    Set-ItemProperty -Path $agentPath -Name "Icon" -Value $iconPath

    $newTermPath = "$base\shell\06_NewTerm"
    $newVerb = if ($Mode -eq "New") { "[X] New terminal" } else { "[ ] New terminal" }
    New-Item -Path $newTermPath -Force -Value $newVerb | Out-Null
    Set-ItemProperty -Path $newTermPath -Name "CommandFlags" -Value 32 -Type DWord

    $appendTermPath = "$base\shell\07_AppendTerm"
    $appendVerb = if ($Mode -eq "Append") { "[X] Append to existing terminal" } else { "[ ] Append to existing terminal" }
    New-Item -Path $appendTermPath -Force -Value $appendVerb | Out-Null

    $wtPrefix = if ($Mode -eq "Append") { "wt.exe -w 0" } else { "wt.exe -w -1" }
    
    $wtAgCmd = New-LLMTerminalCommand $wtPrefix 'agy --dangerously-skip-permissions'
    $wtClaudeCmd = New-LLMTerminalCommand $wtPrefix 'claude --dangerously-skip-permissions'
    $wtCodexCmd = New-LLMTerminalCommand $wtPrefix 'codex --dangerously-bypass-approvals-and-sandbox'
    $wtPiCmd = New-LLMTerminalCommand $wtPrefix 'pi --model openrouter/tencent/hy4-preview'
    $wtAgentCmd = New-LLMTerminalCommand $wtPrefix 'agent -f'

    New-Item -Path "$agPath\command" -Force -Value $wtAgCmd | Out-Null
    New-Item -Path "$claudePath\command" -Force -Value $wtClaudeCmd | Out-Null
    New-Item -Path "$codexPath\command" -Force -Value $wtCodexCmd | Out-Null
    New-Item -Path "$piPath\command" -Force -Value $wtPiCmd | Out-Null
    New-Item -Path "$agentPath\command" -Force -Value $wtAgentCmd | Out-Null

    # Store this checkout's actual path in the registry command.
    $scriptPath = $PSCommandPath
    $newToggleCmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode New"
    $appendToggleCmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Append"

    New-Item -Path "$newTermPath\command" -Force -Value $newToggleCmd | Out-Null
    New-Item -Path "$appendTermPath\command" -Force -Value $appendToggleCmd | Out-Null
}
