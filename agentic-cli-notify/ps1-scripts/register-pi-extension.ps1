#Requires -Version 5.1
param(
    [string]$PiDir = (Join-Path $env:USERPROFILE '.pi\agent'),
    [string]$SourceExtension = (Join-Path (Split-Path $PSScriptRoot -Parent) 'pi-extension\agentic-cli-notify.ts')
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $SourceExtension)) { throw "Extension source not found: $SourceExtension" }
$extDir = Join-Path $PiDir 'extensions'
$null = New-Item -ItemType Directory -Path $extDir -Force
$target = Join-Path $extDir 'agentic-cli-notify.ts'
Copy-Item -LiteralPath $SourceExtension -Destination $target -Force
Write-Host "Pi extension installed: $target"
Write-Host 'Extensions in ~/.pi/agent/extensions are auto-discovered; restart pi to load it.'
