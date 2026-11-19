#Requires -Version 5.1
# Dot-sourced by the launchers, the installer and the Claude /style switch.
# One catalog (styles\styles.json) and one rules file per style serve every agent.

$script:ResponseStyleDir = Join-Path (Split-Path -Parent $PSScriptRoot) "styles"
# A layout `style` set to one of these launches the agent with no style at all.
$script:ResponseStyleOffWords = @("off", "none")

function Get-ResponseStyleCatalog {
    <#
        Return the styles as an ordered key -> @{ Key; Label; Description; RulesPath; IsDefault } map.
        An unreadable catalog yields an empty map: a tab must still launch without a style.
    #>
    param([string]$StylesDir = $script:ResponseStyleDir)

    $catalog = [ordered]@{}
    $catalogPath = Join-Path $StylesDir "styles.json"
    if (-not (Test-Path -LiteralPath $catalogPath)) { return $catalog }

    try {
        $json = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "[DevLayout] could not parse ${catalogPath}: $($_.Exception.Message)"
        return $catalog
    }

    foreach ($prop in $json.PSObject.Properties) {
        $key = $prop.Name.ToLowerInvariant()
        $catalog[$key] = @{
            Key         = $key
            Label       = [string]$prop.Value.label
            Description = [string]$prop.Value.description
            RulesPath   = Join-Path $StylesDir ([string]$prop.Value.file)
            IsDefault   = ($prop.Value.default -eq $true)
        }
    }
    return $catalog
}

function Get-DefaultResponseStyleKey {
    <# The catalog entry marked "default": true, or $null when none is. #>
    param([string]$StylesDir = $script:ResponseStyleDir)

    foreach ($entry in (Get-ResponseStyleCatalog -StylesDir $StylesDir).Values) {
        if ($entry.IsDefault) { return $entry.Key }
    }
    return $null
}

function Test-ResponseStyleOff {
    param([string]$Name)

    return ($Name -and ($script:ResponseStyleOffWords -contains $Name.Trim().ToLowerInvariant()))
}

function Resolve-ResponseStyle {
    <#
        Map a layout `style` value (catalog key or label, any case) to its entry plus
        the rules text. Empty input means the catalog default. "off"/"none", an
        unknown name or a missing rules file returns $null, so the caller launches
        the agent untouched.
    #>
    param(
        [string]$Name,
        [string]$StylesDir = $script:ResponseStyleDir
    )

    if (Test-ResponseStyleOff -Name $Name) { return $null }
    if (-not $Name -or -not $Name.Trim()) {
        $Name = Get-DefaultResponseStyleKey -StylesDir $StylesDir
        if (-not $Name) { return $null }
    }

    $wanted = $Name.Trim().ToLowerInvariant()
    $catalog = Get-ResponseStyleCatalog -StylesDir $StylesDir
    $entry = $null
    foreach ($candidate in $catalog.Values) {
        if ($candidate.Key -eq $wanted -or $candidate.Label.ToLowerInvariant() -eq $wanted) {
            $entry = $candidate
            break
        }
    }

    if (-not $entry) {
        Write-Warning "[DevLayout] unknown response style '$Name'; launching without one. Known: $($catalog.Keys -join ', ')."
        return $null
    }
    if (-not (Test-Path -LiteralPath $entry.RulesPath)) {
        Write-Warning "[DevLayout] rules file missing for style '$($entry.Key)': $($entry.RulesPath)"
        return $null
    }

    $resolved = $entry.Clone()
    # LF only: a CRLF checkout must yield the same bytes for every agent and for the installer.
    $resolved.Text = (Get-Content -LiteralPath $entry.RulesPath -Raw -Encoding UTF8).Replace("`r`n", "`n").Trim()
    return $resolved
}

function ConvertTo-ClaudeOutputStyle {
    <# Claude Code output style file: YAML frontmatter plus the shared rules. #>
    param([hashtable]$Style)

    return "---`nname: $($Style.Label)`ndescription: $($Style.Description)`nkeep-coding-instructions: true`n---`n`n$($Style.Text)`n"
}

function Get-ClaudeOutputStylePath {
    param(
        [hashtable]$Style,
        [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude")
    )

    return Join-Path (Join-Path $ClaudeDir "output-styles") ("agentic-" + $Style.Key + ".md")
}

function ConvertTo-CodexInstructionArg {
    <#
        Build the `-c developer_instructions=...` value as a TOML multi-line literal
        string. Windows PowerShell 5.1 mangles double quotes in native arguments and a
        literal string has no escapes, so double quotes become single ones and any run
        of three quotes, which would end the literal early, is shortened.
    #>
    param([string]$Text)

    $safe = ($Text -replace '"', "'") -replace "'{3,}", "''"
    return "developer_instructions='''`n$safe`n'''"
}

$script:CodexStyleBlockStart = "# >>> agentic-cli-toolkit default response style (Install-ResponseStyles.ps1)"
$script:CodexStyleBlockEnd = "# <<< agentic-cli-toolkit default response style"

function Set-CodexStyleBlock {
    <#
        Return config.toml text with the managed developer_instructions block set to
        $Style, or removed when $Style is $null. The block goes first: a top-level key
        after a [table] header would belong to that table. A developer_instructions key
        outside the block throws, since TOML rejects a duplicate key.
    #>
    param(
        [AllowEmptyString()][string]$ConfigText,
        [hashtable]$Style
    )

    $lines = @()
    $inBlock = $false
    foreach ($line in ($ConfigText.Replace("`r`n", "`n") -split "`n")) {
        if ($line -eq $script:CodexStyleBlockStart) { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -eq $script:CodexStyleBlockEnd) { $inBlock = $false }
            continue
        }
        if ($line -match '^\s*developer_instructions\s*=') {
            throw "config.toml already sets developer_instructions outside the managed block. Remove it first."
        }
        $lines += $line
    }

    $rest = ($lines -join "`n").TrimStart("`n")
    if (-not $Style) { return $rest }

    $block = $script:CodexStyleBlockStart + "`n" + (ConvertTo-CodexInstructionArg -Text $Style.Text) + "`n" + $script:CodexStyleBlockEnd + "`n"
    if ($rest) { return $block + "`n" + $rest }
    return $block
}

function Get-PiStyleShimPath {
    param([string]$PiDir = (Join-Path $env:USERPROFILE ".pi\agent"))

    return Join-Path (Join-Path $PiDir "extensions") "agentic-cli-style.ts"
}

function ConvertTo-PiStyleShim {
    <#
        Global pi extension that loads the checkout's style extension, so a bare `pi`
        gets the default style. The styles directory is set only when the launcher
        has not set it already.
    #>
    param([string]$StylesDir = $script:ResponseStyleDir)

    $dir = [IO.Path]::GetFullPath($StylesDir).Replace('\', '/')
    $extension = "$dir/pi-extension/agentic-cli-style.ts"
    return "// Generated by agentic-cli-toolkit Install-ResponseStyles.ps1. Edit the checkout, not this file.`n" +
        "import style from `"$extension`";`n`n" +
        "export default function (pi: any) {`n" +
        "  process.env.AGENTIC_STYLES_DIR ??= `"$dir`";`n" +
        "  return style(pi);`n" +
        "}`n"
}
