#Requires -Version 5.1
param(
    [string]$CodexDir = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.claude\hooks\agentic-cli-notify')
)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$wpf = Join-Path (Split-Path $compiler) 'WPF'
if (-not (Test-Path -LiteralPath $compiler)) { throw ".NET Framework compiler not found: $compiler" }
$null = New-Item -ItemType Directory -Path $InstallDir -Force
foreach ($file in @('notify.ps1', 'popup.ps1', 'codex-hook.ps1', 'attention.cmd', 'resume.cmd', 'setup.sh', 'SaveHwnd.cs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $InstallDir -Force
}
& $compiler -nologo -optimize+ "-out:$InstallDir\save-hwnd.exe" "$InstallDir\SaveHwnd.cs" `
    "-r:$wpf\UIAutomationClient.dll" "-r:$wpf\UIAutomationTypes.dll" '-r:System.Management.dll'
if ($LASTEXITCODE -ne 0) { throw 'save-hwnd.exe compilation failed.' }
& (Join-Path $PSScriptRoot 'register-codex-hooks.ps1') -CodexDir $CodexDir -NotifyDir $InstallDir
Write-Host 'Installed. In Codex, use /hooks to review and trust the two notification hooks.'
Write-Host 'If hooks are disabled, enable hooks = true under [features] in config.toml.'
Write-Host 'From each focused Windows Terminal tab, run:'
Write-Host '  bash ~/.claude/hooks/agentic-cli-notify/setup.sh'
