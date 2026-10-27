<#
.SYNOPSIS
    Decide which branch a plan's implementation runs on, and refuse when that branch is
    not the plan's to use.

.DESCRIPTION
    A plan names its branch in a `Branch:` header line, and `/oimpl` implements a plan on
    that branch. This script is the guard and the lookup in one, so the skills do not each
    restate it. It reads the plan's `Branch:` line the way `Get-PlanContext.ps1` does and
    asks that script for the other plans of the repository, so a branch two plans claim is
    found by the same candidate list everything else uses.

    Without -Branch the plan is expected to be in one of two states. With no `Branch:` line
    it is new: the answer is Mode `new` with no branch, and the caller picks one. With a
    `Branch:` line it must be that plan's alone and the branch must exist; the answer is
    Mode `existing` with the branch and the path of the work tree it is checked out in,
    or -RepoRoot when no work tree has it checked out.

    With -Branch the caller has chosen a branch for a plan that has none. The plan must
    still have none, and no other plan may already name the branch. The answer is Mode
    `new` with the branch.

    Every refusal is a throw that names the plan file and the offending branch.

.PARAMETER Plan
    Absolute path of the plan file. Must exist.

.PARAMETER RepoRoot
    Work tree of the repository the plan is about. Defaults to the current directory.

.PARAMETER Branch
    Branch the caller proposes for a plan that has no `Branch:` line.

.OUTPUTS
    One JSON object on stdout: Mode (`new` or `existing`), Branch, Path.

.EXAMPLE
    pwsh -File Resolve-PlanBranch.ps1 -Plan ~/code/plans/repo/2026-01-01-thing.md

.EXAMPLE
    pwsh -File Resolve-PlanBranch.ps1 -Plan ~/code/plans/repo/2026-01-01-thing.md -Branch thing
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Plan,

    [string]$RepoRoot = '.',

    [string]$Branch
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

if (-not (Test-Path -LiteralPath $Plan -PathType Leaf))
{
    throw "Plan '$Plan' does not exist.";
}

$planPath = (Resolve-Path -LiteralPath $Plan).Path;
$repoRootPath = (Resolve-Path -LiteralPath $RepoRoot).Path;

function Write-Result([string]$Mode, [string]$ResultBranch, [string]$ResultPath)
{
    [pscustomobject]@{
        Mode   = $Mode
        Branch = if ($ResultBranch) { $ResultBranch } else { $null }
        Path   = if ($ResultPath) { $ResultPath } else { $null }
    } | ConvertTo-Json -Compress;
}

# Same header read as Get-PlanContext.ps1: the top of the file, first `Branch:` line.
$planBranch = $null;
foreach ($line in (Get-Content -LiteralPath $planPath -TotalCount 20))
{
    if ($line -match '^Branch:\s*(\S+)') { $planBranch = $Matches[1]; break }
}

$context = & (Join-Path $PSScriptRoot 'Get-PlanContext.ps1') -Path $repoRootPath | ConvertFrom-Json;
# Candidates all come from one plan directory, so the file name identifies the plan; a
# path compare would miss it when -Plan was reached through a symlink or in other casing.
$planName = Split-Path $planPath -Leaf;
$others = @(@($context.Candidates) | Where-Object { $_.Name -ine $planName });

# Plan lines are parsed as a single token, so a caller's value gets the same shape.
if ($Branch) { $Branch = ($Branch.Trim() -replace '^refs/heads/', '') }

if (-not $Branch)
{
    if (-not $planBranch)
    {
        Write-Result 'new' $null $null;
        return;
    }

    $clash = @($others | Where-Object { $_.Branch -eq $planBranch }) | Select-Object -First 1;
    if ($clash)
    {
        throw "Plan '$planPath' names branch '$planBranch', which plan '$($clash.Path)' ($($clash.Title)) also names.";
    }

    git -C $repoRootPath rev-parse --verify --quiet "refs/heads/$planBranch" *> $null;
    if ($LASTEXITCODE -ne 0)
    {
        throw "Plan '$planPath' names branch '$planBranch', which does not exist.";
    }

    $worktree = $null;
    $current = $null;
    foreach ($line in @(git -C $repoRootPath worktree list --porcelain))
    {
        if ($line -match '^worktree (.+)$') { $current = $Matches[1] }
        elseif ($line -eq "branch refs/heads/$planBranch") { $worktree = $current; break }
    }

    if (-not $worktree) { $worktree = $repoRootPath }

    Write-Result 'existing' $planBranch $worktree;
    return;
}

if ($planBranch)
{
    throw "Plan '$planPath' already names branch '$planBranch'; the hook should not have been invoked.";
}

$taken = @($others | Where-Object { $_.Branch -eq $Branch }) | Select-Object -First 1;
if ($taken)
{
    throw "Plan '$planPath' cannot use branch '$Branch': plan '$($taken.Path)' ($($taken.Title)) already names it.";
}

Write-Result 'new' $Branch $null;
