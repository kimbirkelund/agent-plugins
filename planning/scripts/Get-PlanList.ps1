<#
.SYNOPSIS
    List the plans that belong to this repository, filtered and ordered for reading in a
    terminal.

.DESCRIPTION
    Plans live in their own git repository, one directory per repository they are about, so
    there is no way to see what is planned for the repository in front of you by looking at
    the working tree. This script is that view.

    Where the plans are is `Get-PlanContext.ps1`'s knowledge, and this script calls it
    rather than restating the layout. What it adds is per-plan facts that only the body of
    the file carries — the goal, how many steps there are, how many `∫∫...∫∫` markers are
    unconsumed, and whether anything stands under `## Open questions` — plus the filtering
    and the order.

    Order is chosen for a terminal, where the last line printed is the one next to the
    prompt and the first may have scrolled away: spent plans first, then plans that have
    not started, and the plans in flight last. Within a group the oldest `Updated:` comes
    first, so the plan touched most recently is nearest the prompt.

    Every unfinished plan carries the `Key` `Get-PlanContext.ps1` gave it — `A`, `B`, ...
    `Z`, `AA` — the letter `/pln` and `/oimpl` take as a selector. The letters are not
    assigned here: the context script hands them out in this same order, so the first
    unfinished plan listed is `A` and the keys ascend down the listing. Spent plans have
    none, and lead the listing when -All is passed, so `A` is not always the first line.

    Spent plans are excluded unless -All is passed. A plan whose `Status:` is neither
    PLANNING, IMPLEMENTING nor DONE is never hidden: an unreadable status is a problem to
    see, not a plan to filter away.

.PARAMETER All
    Include plans with Status DONE. Without it only the unfinished plans are listed.

.PARAMETER Path
    Work tree to list the plans of. Defaults to the current directory.

.PARAMETER ConfigPath
    Configuration file to read instead of the default location.

.OUTPUTS
    One JSON object on stdout.

.EXAMPLE
    pwsh -File Get-PlanList.ps1

.EXAMPLE
    pwsh -File Get-PlanList.ps1 -All
#>
[CmdletBinding()]
param(
    [switch]$All,

    [string]$Path = '.',

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

function Get-Section([string[]]$Lines, [string]$Heading)
{
    $body = @();
    $inside = $false;

    foreach ($line in $Lines)
    {
        if ($line -match '^##\s+(.+?)\s*$')
        {
            if ($inside) { break }
            $inside = ($Matches[1] -eq $Heading);
            continue;
        }

        if ($inside) { $body += $line }
    }

    # Emitted unrolled, so callers can pipe the lines straight into a filter.
    return $body;
}

function Measure-OpenQuestion([string[]]$Lines)
{
    # `none` under the heading is an answer, not an entry; the plan template's own prose is
    # not one either, but a plan that still carries it has not been written yet and the
    # count is moot.
    $entries = @(Get-Section $Lines 'Open questions' |
            Where-Object { $_.Trim() } |
            Where-Object { $_.Trim() -notmatch '^<!--' } |
            Where-Object { $_.Trim() -notmatch '^(none|n/a|-|—)\.?$' });

    return $entries.Count;
}

function Get-PlanDetail([string]$PlanPath)
{
    $text = Get-Content -Raw -LiteralPath $PlanPath;
    $lines = $text -split '\r?\n';

    # The goal's first paragraph, rewrapped: markdown wraps it over several lines and one
    # of those on its own is a sentence fragment.
    $goalLines = @();
    foreach ($line in @(Get-Section $lines 'Goal'))
    {
        if (-not $line.Trim())
        {
            if ($goalLines.Count -gt 0) { break }
            continue;
        }

        $goalLines += $line.Trim();
    }

    $goal = if ($goalLines.Count -gt 0) { $goalLines -join ' ' } else { $null }
    $steps = @(Get-Section $lines 'Steps' | Where-Object { $_ -match '^\s*\d+\.\s' }).Count;

    return [pscustomobject]@{
        Goal          = $goal
        Steps         = $steps
        Markers       = [regex]::Matches($text, '∫∫.*?∫∫', 'Singleline').Count
        OpenQuestions = (Measure-OpenQuestion $lines)
    }
}

function Get-PlanGroup([string]$Status)
{
    switch ($Status)
    {
        'IMPLEMENTING' { return 'ongoing' }
        'PLANNING' { return 'not-started' }
        'DONE' { return 'done' }
        default { return 'unknown' }
    }
}

# This rank must agree with the one Get-PlanContext.ps1 hands the keys out by, or the
# letters would not ascend down the listing. It stays here because the context output
# carries no rank to sort on — a spent plan has no key at all — and a test pins the two
# orders together.
function Get-GroupOrder([string]$Group)
{
    switch ($Group)
    {
        'done' { return 0 }
        'unknown' { return 1 }
        'not-started' { return 2 }
        'ongoing' { return 3 }
        default { return 1 }
    }
}

$contextArgs = @{ Path = $Path };
if ($ConfigPath) { $contextArgs['ConfigPath'] = $ConfigPath }

# Call the context script rather than re-deriving the layout: it owns where plans live and
# which one is current, and two answers to that question is one too many.
$context = & (Join-Path $PSScriptRoot 'Get-PlanContext.ps1') @contextArgs | ConvertFrom-Json;

$plans = @();
foreach ($candidate in @($context.Candidates))
{
    $group = Get-PlanGroup $candidate.Status;
    if ($group -eq 'done' -and -not $All) { continue }

    $detail = Get-PlanDetail $candidate.Path;

    $plans += [pscustomobject]@{
        Path          = $candidate.Path
        Name          = $candidate.Name
        Key           = $candidate.Key
        Title         = $candidate.Title
        Status        = $candidate.Status
        Group         = $group
        Branch        = $candidate.Branch
        Updated       = $candidate.Updated
        IsCurrent     = ($context.PlanPath -and $candidate.Path -eq $context.PlanPath)
        Goal          = $detail.Goal
        Steps         = $detail.Steps
        Markers       = $detail.Markers
        OpenQuestions = $detail.OpenQuestions
    }
}

$plans = @($plans | Sort-Object @{ Expression = { Get-GroupOrder $_.Group } }, Updated, Name);

[pscustomobject]@{
    PlanDir      = $context.PlanDir
    PlansRepo    = $context.PlansRepo
    RepoRoot     = $context.RepoRoot
    RepoName     = $context.RepoName
    Branch       = $context.Branch
    CurrentPlan  = $context.PlanPath
    IncludedDone = [bool]$All
    Total        = @($context.Candidates).Count
    Listed       = $plans.Count
    Plans        = $plans
} | ConvertTo-Json -Depth 5
