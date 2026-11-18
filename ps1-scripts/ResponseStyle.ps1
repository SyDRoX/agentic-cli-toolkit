#Requires -Version 5.1
# Dot-sourced by the launchers, the installer and the Claude /style switch.
# One catalog (styles\styles.json) and one rules file per style serve every agent.

$script:ResponseStyleDir = Join-Path (Split-Path -Parent $PSScriptRoot) "styles"

function Get-ResponseStyleCatalog {
    <#
        Return the styles as an ordered key -> @{ Key; Label; Description; RulesPath } map.
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
        }
    }
    return $catalog
}

function Resolve-ResponseStyle {
    <#
        Map a layout `style` value (catalog key or label, any case) to its entry plus
        the rules text. Empty input, an unknown name or a missing rules file returns
        $null, so the caller launches the agent untouched.
    #>
    param(
        [string]$Name,
        [string]$StylesDir = $script:ResponseStyleDir
    )

    if (-not $Name -or -not $Name.Trim()) { return $null }

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
    $resolved.Text = (Get-Content -LiteralPath $entry.RulesPath -Raw -Encoding UTF8).Trim()
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
