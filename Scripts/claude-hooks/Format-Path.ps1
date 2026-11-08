<#
.SYNOPSIS
    Formats and lints files by extension. Shared dispatch for the Claude Code hooks.
.DESCRIPTION
    PowerShell files are formatted with Invoke-Formatter and linted with Invoke-ScriptAnalyzer,
    both using PSScriptAnalyzerSettings.psd1 from the repository root. Markdown, JSON and YAML
    are formatted with prettier. Paths outside the repository, under .git/, or ignored by git
    are skipped. A missing tool is silent success. Failures are printed on stdout and the
    script exits 1; otherwise it exits 0.
.PARAMETER Path
    Files to format. Relative paths resolve against RepoRoot.
.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..')
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$sep = [IO.Path]::DirectorySeparatorChar
$failures = [System.Collections.Generic.List[string]]::new()
$prettier = Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$hasLinter = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)

foreach ($item in $Path)
{
    if ([string]::IsNullOrWhiteSpace($item))
    {
        continue
    }

    $full = [IO.Path]::GetFullPath($item, $root)
    if (-not $full.StartsWith($root + $sep, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf))
    {
        continue
    }

    $relative = $full.Substring($root.Length + 1).Replace('\', '/')
    if ($relative -eq '.git' -or $relative.StartsWith('.git/'))
    {
        continue
    }

    git -C $root check-ignore -q -- $relative 2>$null
    if ($LASTEXITCODE -eq 0)
    {
        continue
    }

    switch ([IO.Path]::GetExtension($full).ToLowerInvariant())
    {
        { $_ -in '.ps1', '.psm1', '.psd1' }
        {
            if (-not $hasLinter -or -not (Test-Path -LiteralPath $settings))
            {
                break
            }

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
                break
            }

            try
            {
                $findings = Invoke-ScriptAnalyzer -Path $full -Settings $settings -ExcludeRule PSUseConsistentWhitespace
            }
            catch
            {
                $failures.Add("${relative}: lint failed: $($_.Exception.Message)")
                break
            }

            foreach ($finding in $findings)
            {
                $failures.Add("${relative}:$($finding.Line) $($finding.RuleName) $($finding.Message)")
            }
        }
        { $_ -in '.md', '.json', '.jsonc', '.yml', '.yaml' }
        {
            if (-not $prettier)
            {
                break
            }

            $output = & $prettier.Source --write $full 2>&1
            if ($LASTEXITCODE -ne 0)
            {
                $failures.Add("${relative}: prettier failed`n$($output -join "`n")")
            }
        }
    }
}

if ($failures.Count -gt 0)
{
    $failures
    exit 1
}

exit 0
