<#
.SYNOPSIS
    Formats and lints PowerShell files with the repository's PSScriptAnalyzer settings.
.DESCRIPTION
    Each file is formatted in place with Invoke-Formatter and then linted with
    Invoke-ScriptAnalyzer, both using PSScriptAnalyzerSettings.psd1 from RepoRoot. A file is
    written back only when the formatter changed it; a UTF-8 BOM is preserved and an empty file
    is skipped. Findings are printed on stdout as "path:line rule message" and the script exits
    1; otherwise it exits 0. A missing PSScriptAnalyzer or settings file prints one line per
    cause, prefixed "not checked: ", on stdout and the script exits 1.
.PARAMETER Path
    Files to format. Relative paths resolve against the current directory. A missing file
    produces a warning and is skipped.
.PARAMETER RepoRoot
    Repository root. Defaults to one level above this script.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$sep = [IO.Path]::DirectorySeparatorChar
$failures = [System.Collections.Generic.List[string]]::new()

$missing = @()
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer))
{
    $missing += 'not checked: PSScriptAnalyzer module not found'
}

if (-not (Test-Path -LiteralPath $settings))
{
    $missing += "not checked: settings file not found: $settings"
}

if ($missing.Count -gt 0)
{
    $missing
    exit 1
}

foreach ($item in $Path)
{
    if ([string]::IsNullOrWhiteSpace($item))
    {
        continue
    }

    $full = [IO.Path]::GetFullPath($item, (Get-Location).ProviderPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf))
    {
        Write-Warning "Skipping missing file: $item"
        continue
    }

    $relative = $full.StartsWith($root + $sep, [StringComparison]::OrdinalIgnoreCase) ? $full.Substring($root.Length + 1).Replace('\', '/') : $full

    try
    {
        $original = Get-Content -LiteralPath $full -Raw
        if (-not [string]::IsNullOrEmpty($original))
        {
            $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $settings
            if ($formatted -cne $original)
            {
                # Get-Content strips a UTF-8 BOM and Set-Content would not restore it.
                $head = Get-Content -LiteralPath $full -AsByteStream -TotalCount 3
                $hasBom = $head.Count -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF
                $encoding = $hasBom ? 'utf8BOM' : 'utf8NoBOM'
                Set-Content -LiteralPath $full -Value $formatted -NoNewline -Encoding $encoding
            }
        }
    }
    catch
    {
        $failures.Add("${relative}: format failed: $($_.Exception.Message)")
        continue
    }

    # No test covers this catch: unreadable or unparsable input already fails in the format
    # step above, so the analyzer throwing on its own is not reproducible.
    try
    {
        $findings = Invoke-ScriptAnalyzer -Path $full -Settings $settings
    }
    catch
    {
        $failures.Add("${relative}: lint failed: $($_.Exception.Message)")
        continue
    }

    foreach ($finding in $findings)
    {
        $failures.Add("${relative}:$($finding.Line) $($finding.RuleName) $($finding.Message)")
    }
}

if ($failures.Count -gt 0)
{
    $failures
    exit 1
}

exit 0
