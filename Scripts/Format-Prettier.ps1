<#
.SYNOPSIS
    Formats files in place with prettier.
.DESCRIPTION
    Runs "prettier --write" on each file, with no prettier config added. A prettier failure is
    printed on stdout as "path: prettier failed" followed by its output, and the script exits
    1; otherwise it exits 0. A missing prettier is silent success,
    unless -Strict is given.
.PARAMETER Path
    Files to format. Relative paths resolve against the current directory. A missing file
    produces a warning and is skipped.
.PARAMETER RepoRoot
    Repository root. Defaults to one level above this script.
.PARAMETER Strict
    Turns a missing prettier into a failure: one line naming the cause is printed on stdout
    and the script exits 1.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..'),
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
$sep = [IO.Path]::DirectorySeparatorChar
$failures = [System.Collections.Generic.List[string]]::new()
$prettier = Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $prettier)
{
    if ($Strict)
    {
        'prettier not found on PATH'
        exit 1
    }

    exit 0
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

    $output = & $prettier.Source --write $full 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        $failures.Add("${relative}: prettier failed`n$($output -join "`n")")
    }
}

if ($failures.Count -gt 0)
{
    $failures
    exit 1
}

exit 0
