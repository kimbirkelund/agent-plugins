<#
.SYNOPSIS
    Tidy up after a plan's request has been merged: update the target branch's worktree
    and remove the plan branch's worktree.

.DESCRIPTION
    Run from inside the repository (any of its worktrees). Both worktrees are found from
    `git worktree list --porcelain`.

    When Target is checked out in a worktree, `git pull --ff-only` runs there so the
    merged work arrives locally. When Branch is checked out in a linked worktree, it is
    removed with `git worktree remove` from the main worktree, never with --force: a
    worktree with uncommitted changes is reported and left. The main worktree is never
    removed and the local branch is never deleted. A failed pull does not prevent the
    removal.

    Writes one JSON object: RepoRoot (the main worktree), TargetPath, Pulled,
    WorktreePath, Removed, and Reason when a part was skipped or failed. Reason is a
    comma-separated list drawn from target-not-checked-out, pull-failed, dirty,
    main-worktree, no-worktree and remove-failed. `dirty` means the worktree has modified or
    untracked files; any other removal failure (a locked worktree, say) is remove-failed and
    Message holds git's error text.

.PARAMETER Branch
    The plan's branch.

.PARAMETER Target
    The branch the request was merged into.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Branch,

    [Parameter(Mandatory)]
    [string] $Target
)

$ErrorActionPreference = 'Stop';
Set-StrictMode -Version Latest;

$worktrees = @();
$current = $null;
foreach ($line in @(git worktree list --porcelain))
{
    if ($line -match '^worktree (.+)$')
    {
        $current = [pscustomobject]@{ Path = $Matches[1]; Branch = $null };
        $worktrees += $current;
    }
    elseif ($line -match '^branch refs/heads/(.+)$')
    {
        $current.Branch = $Matches[1];
    }
}

if ($LASTEXITCODE -ne 0 -or $worktrees.Count -eq 0)
{
    throw 'Not inside a git repository.';
}

$repoRoot = $worktrees[0].Path;
$reasons = @();

$targetPath = $null;
$pulled = $false;
$targetTree = $worktrees | Where-Object { $_.Branch -eq $Target } | Select-Object -First 1;
if ($targetTree)
{
    $targetPath = $targetTree.Path;
    if ($PSCmdlet.ShouldProcess($targetPath, "git pull --ff-only ($Target)"))
    {
        $null = git -C $targetPath pull --ff-only 2>&1;
        if ($LASTEXITCODE -eq 0) { $pulled = $true }
        else { $reasons += 'pull-failed' }
    }
}
else
{
    $reasons += 'target-not-checked-out';
}

$worktreePath = $null;
$removed = $false;
$message = $null;
$branchTree = $worktrees | Where-Object { $_.Branch -eq $Branch } | Select-Object -First 1;
if (-not $branchTree)
{
    $reasons += 'no-worktree';
}
elseif ($branchTree.Path -eq $repoRoot)
{
    $worktreePath = $branchTree.Path;
    $reasons += 'main-worktree';
}
else
{
    $worktreePath = $branchTree.Path;
    if ($PSCmdlet.ShouldProcess($worktreePath, 'git worktree remove'))
    {
        $output = git -C $repoRoot worktree remove $worktreePath 2>&1;
        if ($LASTEXITCODE -eq 0) { $removed = $true }
        else
        {
            $message = (@($output) | Out-String).Trim();
            $status = @(git -C $worktreePath status --porcelain 2>$null);
            if ($status.Count -gt 0) { $reasons += 'dirty' }
            else { $reasons += 'remove-failed' }
        }
    }
}

$result = [ordered]@{
    RepoRoot     = $repoRoot
    TargetPath   = $targetPath
    Pulled       = $pulled
    WorktreePath = $worktreePath
    Removed      = $removed
};
if ($reasons.Count -gt 0) { $result.Reason = $reasons -join ',' }
if ($message) { $result.Message = $message }

$result | ConvertTo-Json;
