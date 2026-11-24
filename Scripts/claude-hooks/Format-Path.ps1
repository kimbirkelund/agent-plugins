<#
.SYNOPSIS
    Resolves paths, applies the skip rules and dispatches files by extension to the format scripts.
.DESCRIPTION
    Paths outside the repository, under .git/, missing, or ignored by git are skipped. The rest
    are grouped by extension and each group goes, as absolute paths, to one call of the matching
    script in Scripts/: Format-PowerShell.ps1 (.ps1 .psm1 .psd1), Format-Prettier.ps1 (.json
    .jsonc .yml .yaml) or Format-Markdown.ps1 (.md). Unknown extensions are ignored. The stdout
    lines of each script that exits non-zero are split by the "not checked: " prefix. Lines
    without it are printed under "Format and lint: fix these in the files you just wrote."; lines
    with it under "Format and lint could not run, so some files were not checked. Tell the user,
    and ask before installing tools or changing config.". A group with no lines is left out. The
    script exits 1 when either group has lines, otherwise it exits 0 with no output. Warnings the
    scripts write to stderr are not part of the result.
.PARAMETER Path
    Files to format. Relative paths resolve against RepoRoot.
.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script.
.PARAMETER ScriptRoot
    Directory holding the Format-*.ps1 scripts. Defaults to one level above this script.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..'),
    [string]$ScriptRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
$sep = [IO.Path]::DirectorySeparatorChar
$failures = [System.Collections.Generic.List[string]]::new()

$scriptByExtension = @{
    '.ps1'   = 'Format-PowerShell.ps1'
    '.psm1'  = 'Format-PowerShell.ps1'
    '.psd1'  = 'Format-PowerShell.ps1'
    '.json'  = 'Format-Prettier.ps1'
    '.jsonc' = 'Format-Prettier.ps1'
    '.yml'   = 'Format-Prettier.ps1'
    '.yaml'  = 'Format-Prettier.ps1'
    '.md'    = 'Format-Markdown.ps1'
}

$groups = [ordered]@{}
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

    $script = $scriptByExtension[[IO.Path]::GetExtension($full).ToLowerInvariant()]
    if (-not $script)
    {
        continue
    }

    if (-not $groups.Contains($script))
    {
        $groups[$script] = [System.Collections.Generic.List[string]]::new()
    }

    $groups[$script].Add($full)
}

foreach ($script in $groups.Keys)
{
    try
    {
        $output = & (Join-Path $ScriptRoot $script) -Path $groups[$script].ToArray() -RepoRoot $root 3>$null
        if ($LASTEXITCODE -ne 0)
        {
            foreach ($line in $output)
            {
                $failures.Add([string]$line)
            }
        }
    }
    catch
    {
        $failures.Add("not checked: ${script} failed: $($_.Exception.Message)")
    }
}

$notCheckedPrefix = 'not checked: '
$notChecked = @($failures | Where-Object { $_.StartsWith($notCheckedPrefix, [StringComparison]::Ordinal) })
$problems = @($failures | Where-Object { -not $_.StartsWith($notCheckedPrefix, [StringComparison]::Ordinal) })

if ($problems.Count -gt 0)
{
    'Format and lint: fix these in the files you just wrote.'
    $problems
}

if ($notChecked.Count -gt 0)
{
    'Format and lint could not run, so some files were not checked. Tell the user, and ask before installing tools or changing config.'
    $notChecked
}

if ($failures.Count -gt 0)
{
    exit 1
}

exit 0
