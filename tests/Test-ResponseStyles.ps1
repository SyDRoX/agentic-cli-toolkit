#Requires -Version 5.1
# Standalone regression test; no Pester and no installed agent CLI required.
$ErrorActionPreference = "Stop"
$toolkitDir = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $toolkitDir "ps1-scripts\Install-ResponseStyles.ps1"
. (Join-Path $toolkitDir "ps1-scripts\ResponseStyle.ps1")
. (Join-Path $toolkitDir "ps1-scripts\LayoutEngine.ps1")

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("response-style-test-" + [guid]::NewGuid())
$claudeDir = Join-Path $tempRoot "claude [isolated]"
$codexDir = Join-Path $tempRoot "codex"
$piDir = Join-Path $tempRoot "pi agent"
$cavemanDir = Join-Path $tempRoot "caveman-config"
$switch = Join-Path $claudeDir "skills\style\Switch-ResponseStyle.ps1"
$settings = Join-Path $claudeDir "settings.json"

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected error matching: $Pattern"
}
function Invoke-Switch([string]$Style, [string]$SessionId = "") {
    return (& $switch -Style $Style -SessionId $SessionId -ClaudeDir $claudeDir -CavemanConfigDir $cavemanDir) -join "`n"
}

try {
    # --- catalog and resolution
    $catalog = Get-ResponseStyleCatalog
    Assert-True ($catalog.Contains("ste") -and $catalog.Contains("caveman")) "Catalog must hold ste and caveman"
    Assert-True ((Get-DefaultResponseStyleKey) -eq "ste") "ste must be the catalog default"
    Assert-True ((Resolve-ResponseStyle -Name "").Key -eq "ste") "Empty style must resolve to the default"
    Assert-True ($null -eq (Resolve-ResponseStyle -Name "OFF")) "off must resolve to null"
    Assert-True ($null -eq (Resolve-ResponseStyle -Name "none")) "none must resolve to null"
    Assert-True ($null -eq (Resolve-ResponseStyle -Name "nope" 3>$null)) "Unknown style must resolve to null"
    $ste = Resolve-ResponseStyle -Name "STE"
    Assert-True ($ste.Label -eq "ASD-STE100" -and $ste.Text.Length -gt 200) "ste must resolve by key, any case"
    Assert-True ((Resolve-ResponseStyle -Name "asd-ste100").Key -eq "ste") "ste must resolve by label"

    # --- Codex argument: one TOML literal string, safe for 5.1 native argument passing
    $arg = ConvertTo-CodexInstructionArg -Text "a `"quoted`" word and ''''four'''' quotes"
    Assert-True ($arg.StartsWith("developer_instructions='''`n") -and $arg.EndsWith("`n'''")) "Codex value must be a multi-line literal"
    $inner = $arg.Substring("developer_instructions='''".Length, $arg.Length - "developer_instructions='''".Length - 3)
    Assert-True (-not $inner.Contains('"')) "Codex value must not contain double quotes"
    Assert-True (-not $inner.Contains("'''")) "Codex value must not contain a literal terminator"
    foreach ($key in $catalog.Keys) {
        $bundled = ConvertTo-CodexInstructionArg -Text (Resolve-ResponseStyle -Name $key).Text
        Assert-True ($bundled.IndexOf("'''", "developer_instructions='''".Length) -eq $bundled.Length - 3) "Bundled style '$key' ends the Codex literal early"
    }

    # --- engine passes the style as the seventh launcher argument
    $layout = @{ WindowNum = 900; Tabs = @(
        @{ Title = "A"; WorkingDir = "C:\x"; AgentName = "Pi"; LauncherScript = "launch-pi.ps1"; Style = "ste" },
        @{ Title = "B"; WorkingDir = "C:\y"; AgentName = "Codex"; LauncherScript = "launch-codex.ps1" }
    ) }
    $segments = @(Build-LayoutSegments -Layout $layout -PwshExe "powershell.exe")
    Assert-True ($segments[0] -match "'' '' '' 'ste'") "Styled tab must end with its style argument: $($segments[0])"
    Assert-True ($segments[1] -match "'' '' '' ''") "Unstyled tab must pass an empty style argument: $($segments[1])"

    # --- Codex config.toml block
    $toml = "model = `"x`"`r`n`r`n[features]`r`na = true`r`n"
    $withBlock = Set-CodexStyleBlock -ConfigText $toml -Style $ste
    Assert-True ($withBlock.StartsWith("# >>> agentic-cli-toolkit")) "Block must come before any table"
    Assert-True ($withBlock.EndsWith("[features]`na = true`n")) "Block insert lost the rest of the file"
    Assert-True ((Set-CodexStyleBlock -ConfigText $withBlock -Style $ste) -ceq $withBlock) "Block insert is not idempotent"
    Assert-True ((Set-CodexStyleBlock -ConfigText $withBlock -Style $null) -ceq $toml.Replace("`r`n", "`n")) "Block removal must restore the file"
    Assert-Throws { Set-CodexStyleBlock -ConfigText "developer_instructions = 'x'" -Style $ste } "*outside the managed block*"

    # --- installer
    New-Item -ItemType Directory -Path $codexDir, $piDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $codexDir "config.toml"), $toml)
    function Invoke-Installer { & $installer -ClaudeDir $claudeDir -CodexDir $codexDir -PiDir $piDir @args }
    Invoke-Installer -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $claudeDir)) "WhatIf created directories"
    Assert-True ([IO.File]::ReadAllText((Join-Path $codexDir "config.toml")) -ceq $toml) "WhatIf changed config.toml"

    Invoke-Installer
    Assert-True ([IO.File]::ReadAllText((Join-Path $codexDir "config.toml")) -ceq $withBlock) "Installer must write the Codex default block"
    $shim = [IO.File]::ReadAllText((Get-PiStyleShimPath -PiDir $piDir))
    Assert-True ($shim.Contains("/styles/pi-extension/agentic-cli-style.ts`"") -and $shim.Contains("AGENTIC_STYLES_DIR ??=")) "pi shim content wrong"
    $steFile = Join-Path $claudeDir "output-styles\agentic-ste.md"
    $steText = [IO.File]::ReadAllText($steFile)
    Assert-True ($steText.StartsWith("---`nname: ASD-STE100`n")) "Output style frontmatter missing"
    Assert-True ($steText.Contains($ste.Text)) "Output style must carry the shared rules"
    Assert-True (Test-Path -LiteralPath (Join-Path $claudeDir "output-styles\agentic-caveman.md")) "Caveman output style missing"
    Assert-True (-not (Test-Path -LiteralPath $settings)) "Installer must not create settings.json"

    $timestamp = (Get-Item -LiteralPath $steFile).LastWriteTimeUtc
    Invoke-Installer
    Assert-True ((Get-Item -LiteralPath $steFile).LastWriteTimeUtc -eq $timestamp) "Repeat install rewrote a file"

    [IO.File]::WriteAllText($steFile, "user edit")
    Assert-Throws { Invoke-Installer } "File differs:*"
    Assert-True ([IO.File]::ReadAllText($steFile) -eq "user edit") "Failed install changed the differing file"
    Invoke-Installer -Force
    Assert-True ([IO.File]::ReadAllText($steFile) -eq $steText) "Force did not restore the output style"

    # --- /style switch
    $original = "{`n  `"model`": `"x`",`n  `"hooks`": { `"a`": [1, 2] }`n}`n"
    [IO.File]::WriteAllText($settings, $original)
    $out = Invoke-Switch "ste" "abc-123"
    Assert-True ($out -match "STYLE SWITCHED: ASD-STE100" -and $out.Contains("controlled plain English")) "Switch must print the new rules"
    $after = [IO.File]::ReadAllText($settings)
    Assert-True (($after | ConvertFrom-Json).outputStyle -eq "ASD-STE100") "outputStyle not inserted"
    Assert-True ($after.Contains('"hooks": { "a": [1, 2] }')) "Switch reformatted settings.json"
    Assert-True ([IO.File]::ReadAllText((Join-Path $claudeDir "style-sessions\abc-123")) -eq "ste") "Session flag missing"
    Assert-True (-not (Test-Path -LiteralPath $cavemanDir)) "Switch touched caveman config for a non-user of the plugin"

    $out = Invoke-Switch "toggle"
    Assert-True ($out -match "STYLE SWITCHED: Caveman \(was ASD-STE100\)") "Toggle must move to the next style"
    Assert-True (([IO.File]::ReadAllText($settings) | ConvertFrom-Json).outputStyle -eq "Caveman") "outputStyle not replaced"
    Assert-True ((Invoke-Switch "status") -eq "style: caveman (Caveman)") "Status mismatch"
    Assert-True ((Invoke-Switch "bogus") -match "unknown style") "Unknown style must be reported"

    # Caveman plugin users: the default mode follows the style.
    New-Item -ItemType Directory -Path $cavemanDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cavemanDir "config.json"), '{"defaultMode":"full","other":1}')
    $null = Invoke-Switch "ste"
    $config = Get-Content -LiteralPath (Join-Path $cavemanDir "config.json") -Raw | ConvertFrom-Json
    Assert-True ($config.defaultMode -eq "off" -and $config.other -eq 1) "Caveman plugin mode not turned off"
    $null = Invoke-Switch "caveman"
    Assert-True ((Get-Content -LiteralPath (Join-Path $cavemanDir "config.json") -Raw | ConvertFrom-Json).defaultMode -eq "full") "Caveman plugin mode not restored"
    Assert-True ([IO.File]::ReadAllText((Join-Path $claudeDir ".caveman-active")) -eq "full") "Caveman flag missing"

    # settings.json without the key and with an empty object.
    [IO.File]::WriteAllText($settings, "{}")
    $null = Invoke-Switch "ste"
    Assert-True (([IO.File]::ReadAllText($settings) | ConvertFrom-Json).outputStyle -eq "ASD-STE100") "Empty settings object not handled"

    Write-Host "Response style tests passed." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
