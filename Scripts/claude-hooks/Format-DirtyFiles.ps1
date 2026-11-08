<#
.SYNOPSIS
    PostToolUse hook for Bash: formats modified and untracked files changed since the last run.
.DESCRIPTION
    Ignores stdin. Edits made through a shell command are invisible to the Write/Edit hook,
    so this finds them via git status. Files newer than the stamp file in the git dir are
    passed to Format-Path.ps1 in one call; with no stamp yet, every dirty file is a candidate.
    The stamp is touched after formatting so the formatters' own rewrites do not re-trigger.
    Exits 0 for success or nothing to do; on failure writes the text to stderr and exits 2.
.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..')
)

# Anything that goes wrong while finding files exits 0, so this hook never blocks editing.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue))
{
    exit 0
}

try
{
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
    $gitDir = git -C $root rev-parse --git-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $gitDir)
    {
        exit 0
    }

    $stamp = [IO.Path]::GetFullPath($gitDir, $root) + [IO.Path]::DirectorySeparatorChar + 'claude-format-hook-stamp'
    $stampTime = (Test-Path -LiteralPath $stamp) ? [IO.File]::GetLastWriteTimeUtc($stamp) : $null

    function Split-GitZ
    {
        param([string[]]$Raw)

        ($Raw -join "`n") -split "`0" | Where-Object { $_ -ne '' }
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    function Add-Candidate
    {
        param([string]$Relative)

        $full = Join-Path $root $Relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf))
        {
            return
        }

        if ($null -eq $stampTime -or [IO.File]::GetLastWriteTimeUtc($full) -gt $stampTime)
        {
            $candidates.Add($full)
        }
    }

    # Records are "XY path"; a rename or copy is followed by an extra record holding the old path.
    $skipNext = $false
    foreach ($record in Split-GitZ (git -C $root status --porcelain -z 2>$null))
    {
        if ($skipNext)
        {
            $skipNext = $false
            continue
        }

        $status = $record.Substring(0, 2)
        $relative = $record.Substring(3)
        if ($status -match '^(R.|C.|.R|.C)$')
        {
            $skipNext = $true
        }

        if ($status -match 'D|U' -or $status -eq 'AA')
        {
            continue
        }

        if ($relative.EndsWith('/'))
        {
            foreach ($inner in Split-GitZ (git -C $root ls-files --others --exclude-standard -z -- $relative 2>$null))
            {
                Add-Candidate $inner
            }
        }
        else
        {
            Add-Candidate $relative
        }
    }
}
catch
{
    # Never block editing because git or its output was unusable.
    exit 0
}

$failed = $false
$text = ''
if ($candidates.Count -gt 0)
{
    try
    {
        $text = (& (Join-Path $PSScriptRoot 'Format-Path.ps1') -Path $candidates.ToArray() -RepoRoot $root) -join "`n"
        $failed = $LASTEXITCODE -ne 0
    }
    catch
    {
        $text = "Format-Path.ps1 failed: $($_.Exception.Message)"
        $failed = $true
    }
}

# After formatting, so the formatters' own rewrites do not re-trigger.
try
{
    if (-not (Test-Path -LiteralPath $stamp))
    {
        New-Item -ItemType File -Path $stamp -Force | Out-Null
    }

    [IO.File]::SetLastWriteTimeUtc($stamp, [datetime]::UtcNow)
}
catch
{
    Write-Verbose "Could not touch stamp: $($_.Exception.Message)"
}

if ($failed)
{
    [Console]::Error.WriteLine($text)
    exit 2
}

exit 0
