<#
.SYNOPSIS
    Move a working-tree PLAN.md into the plans repository, in the current plan format.

.DESCRIPTION
    Plans used to live at the root of the repository they were about, as an uncommitted
    PLAN.md. They now live in their own git repository, one directory per repository, one
    file per plan, committed after every write. This script moves one old plan across.

    What it changes is the header block and the location, never the plan's substance:

      - the file lands at <plans repo>/<repo name>/<date>-<slug>.md, dated from when the
        plan was written rather than from today, so the directory stays in the order the
        work happened;
      - a `Repo:` line is added, because the file no longer sits in the repository it is
        about and nothing else records which one that is;
      - `Status:`, `Updated:`, and any `Branch:` or `Base:` lines are carried over as they
        stand. A spent plan stays spent; an interrupted one stays resumable.

    Everything below the header is copied verbatim, unconsumed `∫∫...∫∫` markers included —
    they are the user's own input and migrating is not the moment to answer them. The count
    is reported so the caller can say so.

    The source is deleted only after the destination is committed, and never with
    -KeepSource. A run that writes the destination but cannot commit it removes that file
    again, so the plan is never left half-migrated: the next run sees the same free name
    rather than a taken one, and migrates the plan once instead of twice under a -2 suffix.
    Nothing in the repository being migrated is committed or otherwise touched.

.PARAMETER PlanPath
    Plan to migrate. Defaults to PLAN.md at the root of the repository.

.PARAMETER RepoPath
    Work tree the plan belongs to. Defaults to the current directory.

.PARAMETER KeepSource
    Leave the original file in place after copying it across.

.OUTPUTS
    One JSON object on stdout.

.EXAMPLE
    pwsh -File Migrate-Plan.ps1

.EXAMPLE
    pwsh -File Migrate-Plan.ps1 -PlanPath ~/code/safepilot/PLAN.md -KeepSource
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PlanPath,

    [string]$RepoPath = '.',

    [switch]$KeepSource
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

function Remove-MigratedPlan
{
    param([string]$Path, [string]$PlansRepo)

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue;

    # Save-Plan.ps1 stages the whole repository before it commits, so a commit that failed
    # leaves the file staged as an add. Drop it from the index too, or the next `git status`
    # in the plans repository reports a file that is no longer on disk.
    if ($PlansRepo -and (Test-Path -LiteralPath $PlansRepo -PathType Container))
    {
        git -C $PlansRepo rm --cached --quiet --ignore-unmatch -- $Path 2>$null | Out-Null;
    }
}

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container))
{
    throw "Repository path '$RepoPath' is not a directory.";
}

$searchDir = (Resolve-Path -LiteralPath $RepoPath).Path;

$repoRoot = git -C $searchDir rev-parse --show-toplevel 2>$null;
if ($LASTEXITCODE -ne 0 -or -not $repoRoot)
{
    throw "'$searchDir' is not inside a git work tree.";
}
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path;

if (-not $PlanPath) { $PlanPath = Join-Path $repoRoot 'PLAN.md' }

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf))
{
    throw "No plan at '$PlanPath'. Nothing to migrate.";
}

$planFile = Get-Item -LiteralPath $PlanPath;
$planText = Get-Content -Raw -LiteralPath $planFile.FullName;

if ($planText -match '(?m)^#\s*Plan:\s*(.+?)\s*$') { $title = $Matches[1] }
elseif ($planText -match '(?m)^#\s+(.+?)\s*$') { $title = $Matches[1] }
else { $title = $planFile.BaseName }

if ($planText -notmatch '(?m)^Status:\s*(\S+)')
{
    throw "'$($planFile.FullName)' has no 'Status:' line, so it is not a plan this workflow wrote. Migrate it by hand.";
}
$status = $Matches[1];

# The plan was never committed, so its own timestamps are the only record of when it was
# written. Creation time is the one that matters; fall back when the filesystem lost it.
$created = $planFile.CreationTime;
if ($created.Year -le 1601 -or $created -gt $planFile.LastWriteTime)
{
    $created = $planFile.LastWriteTime;
}

$context = & (Join-Path $PSScriptRoot 'Get-PlanContext.ps1') -Path $repoRoot -Title $title -Date $created | ConvertFrom-Json;
$destination = $context.NewPlanPath;

$migrated = $planText;
if ($migrated -notmatch '(?m)^Repo:\s*\S')
{
    if ($migrated -match '(?m)^(Updated:.*)$')
    {
        $migrated = [regex]::Replace($migrated, '(?m)^(Updated:.*)$', "`$1`nRepo: $repoRoot", 1);
    }
    else
    {
        $migrated = [regex]::Replace($migrated, '(?m)^(Status:.*)$', "`$1`nRepo: $repoRoot", 1);
    }
}

$markers = ([regex]::Matches($migrated, '∫∫')).Count / 2;

$result = [pscustomobject]@{
    Source      = $planFile.FullName
    Destination = $destination
    PlansRepo   = $context.PlansRepo
    RepoRoot    = $repoRoot
    RepoName    = $context.RepoName
    Title       = $title
    Status      = $status
    Created     = $created.ToString('s')
    Markers     = [int]$markers
    Committed   = $false
    Commit      = $null
    SourceKept  = [bool]$KeepSource
};

if ($PSCmdlet.ShouldProcess($destination, 'write migrated plan'))
{
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null;

    # The destination was free when Get-PlanContext.ps1 named it; a file there now means
    # another migration got in first, and overwriting it would lose that plan.
    if (Test-Path -LiteralPath $destination)
    {
        throw "'$destination' appeared while this migration was being prepared. Run it again.";
    }

    Set-Content -LiteralPath $destination -Value $migrated -NoNewline;

    try
    {
        $save = & (Join-Path $PSScriptRoot 'Save-Plan.ps1') -Message "migrate plan: $title" | ConvertFrom-Json;
        $result.Committed = [bool]$save.Committed;
        $result.Commit = $save.Commit;
    }
    catch
    {
        # A written but uncommitted destination is worse than no destination at all: the
        # next run finds the name taken and migrates the same plan a second time under a
        # -2 suffix. Take it back out so a retry lands on the name this run chose.
        Remove-MigratedPlan -Path $destination -PlansRepo $context.PlansRepo;
        throw;
    }

    # The source is the only copy until the destination is committed, so deleting before
    # that point risks losing the plan to a failed commit.
    if ($result.Committed)
    {
        if (-not $KeepSource)
        {
            Remove-Item -LiteralPath $planFile.FullName -Force;
        }
    }
    else
    {
        Remove-MigratedPlan -Path $destination -PlansRepo $context.PlansRepo;
        $result.SourceKept = $true;
    }
}

$result | ConvertTo-Json -Depth 3
