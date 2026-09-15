<#
.SYNOPSIS
    Build LayoutUI.exe (onefile) from layout_ui.py.

.DESCRIPTION
    Installs the runtime + build dependencies if missing, then runs PyInstaller against
    LayoutUI.spec. The exe is written to the repo root rather than dist/ because the app
    reads custom-layouts/, repos.json and ps1-scripts/ from its own folder at runtime.

.PARAMETER Python
    Python interpreter to build with. Defaults to whatever "python" resolves to.

.PARAMETER Clean
    Discard PyInstaller's build cache first. Use after changing the spec or dependencies.

.EXAMPLE
    .\Build-LayoutUI.ps1
    .\Build-LayoutUI.ps1 -Clean -Python "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
#>
[CmdletBinding()]
param(
    [string]$Python = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$repoRoot = $PSScriptRoot

$resolved = Get-Command $Python -ErrorAction SilentlyContinue
if (-not $resolved) {
    throw "Python interpreter '$Python' not found. Pass -Python <path-to-python.exe>."
}
$pythonExe = $resolved.Source
Write-Host "Building with $pythonExe" -ForegroundColor Cyan

$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $pythonExe -c "import customtkinter, PyInstaller" 2>$null
$ErrorActionPreference = $prevEap
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing build dependencies..." -ForegroundColor Yellow
    & $pythonExe -m pip install -r (Join-Path $repoRoot "requirements.txt") -r (Join-Path $repoRoot "requirements-build.txt")
    if ($LASTEXITCODE -ne 0) { throw "Dependency install failed." }
}

$pyiArgs = @(
    "-m", "PyInstaller",
    (Join-Path $repoRoot "LayoutUI.spec"),
    "--distpath", $repoRoot,
    "--workpath", (Join-Path $repoRoot "build"),
    "--noconfirm"
)
if ($Clean) { $pyiArgs += "--clean" }

& $pythonExe @pyiArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE." }

$exe = Join-Path $repoRoot "LayoutUI.exe"
if (-not (Test-Path $exe)) { throw "Build reported success but $exe is missing." }

$sizeMb = [math]::Round((Get-Item $exe).Length / 1MB, 1)
Write-Host "Built $exe ($sizeMb MB)" -ForegroundColor Green
Write-Host "Keep it next to custom-layouts\, repos.json and ps1-scripts\ - they are not bundled."
