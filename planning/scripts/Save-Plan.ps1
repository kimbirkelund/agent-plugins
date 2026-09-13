<#
.SYNOPSIS
    Commit the current state of the plans repository.

.DESCRIPTION
    Plans live in their own repository and are committed after every edit, so the history
    of a plan is the record of how the thinking moved. That makes the commit a mechanical
    step taken many times per session rather than a decision, which is why it is a script
    with a standard message instead of a judgement call in the skill.

    Everything in the plans repository is committed — it holds nothing but plans, so there
    is no partial state worth curating. When there is nothing to commit the script says so
    and exits 0, so a caller may run it after every write without checking first.

    The repository is created and initialised on first use, since a plans repository is
    purely local and one that does not exist yet is a first run rather than a mistake.

    Two sessions planning at once would otherwise race on one index. Every run therefore
    holds a lock for the whole of its git work: `.claude-plan.lock`, a directory, created
    with the one filesystem operation that is atomic on every platform — creating a
    directory that already exists fails rather than succeeding twice. The directory is left
    empty, which is also why it never reaches a commit: git does not track empty
    directories, so the lock is invisible to `git add -A` and to `git status`.

    A lock older than StaleLockSeconds is assumed to belong to a session that died and is
    broken. Nothing here runs for more than a moment, so the default is generous by orders
    of magnitude.

    When the repository has an upstream, the run also pulls and pushes — at most once every
    SyncIntervalSeconds, with the last attempt recorded in .git so every session on the
    machine shares one clock. Sync problems are reported in the output and never thrown: a
    plan that is committed locally is safe, and a remote that is unreachable is not a reason
    to fail the write. A pull that cannot be rebased cleanly is aborted, so the repository is
    never left mid-rebase.

.PARAMETER PlansRepo
    Plans repository to commit. Resolved via Get-PlanContext.ps1 when omitted.

.PARAMETER Message
    Commit message. Defaults to 'update plans'.

.PARAMETER LockTimeoutSeconds
    How long to wait for another session to finish before giving up. Defaults to 30.

.PARAMETER StaleLockSeconds
    Age at which a lock is assumed to belong to a session that died and is broken rather
    than waited on. Defaults to 300.

.PARAMETER SyncIntervalSeconds
    How often to pull and push, in seconds. Defaults to 300. The clock is per repository,
    kept in .git, so it is shared by every session on this machine.

.PARAMETER SyncNow
    Pull and push regardless of how long it has been.

.PARAMETER NoSync
    Commit locally and do not touch the remote at all.

.OUTPUTS
    One JSON object on stdout.

.EXAMPLE
    pwsh -File Save-Plan.ps1

.EXAMPLE
    pwsh -File Save-Plan.ps1 -Message 'plan: move plans into their own repo'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PlansRepo,

    [string]$Message = 'update plans',

    [int]$LockTimeoutSeconds = 30,

    [int]$StaleLockSeconds = 300,

    [int]$SyncIntervalSeconds = 300,

    [switch]$SyncNow,

    [switch]$NoSync
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

function Enter-PlanLock
{
    param([string]$Path, [int]$TimeoutSeconds, [int]$StaleSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds);
    $broke = $false;

    while ($true)
    {
        try
        {
            # mkdir is the atomic primitive: it fails when the directory exists, so exactly
            # one caller can win. -Force would defeat that by succeeding either way.
            New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null;
            return [pscustomobject]@{ Broke = $broke }
        }
        catch
        {
            if (-not (Test-Path -LiteralPath $Path)) { throw }

            $held = $null;
            try
            {
                $item = Get-Item -LiteralPath $Path -Force;
                $held = if ($item.CreationTime.Year -gt 1601) { $item.CreationTime } else { $item.LastWriteTime }
            }
            catch { $held = $null }

            if ($held -and ((Get-Date) - $held).TotalSeconds -gt $StaleSeconds)
            {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue;
                $broke = $true;
                continue;
            }

            if ((Get-Date) -gt $deadline)
            {
                $age = if ($held) { [int]((Get-Date) - $held).TotalSeconds } else { -1 }
                throw "Timed out after $TimeoutSeconds s waiting for the plans repository lock at '$Path' (held for $age s). Another session is writing a plan; retry, or remove the directory if nothing is.";
            }

            Start-Sleep -Milliseconds 200;
        }
    }
}

function Sync-PlansRepo
{
    param([string]$Repo, [int]$IntervalSeconds, [switch]$Force)

    $result = [pscustomobject]@{ Attempted = $false; Pulled = $false; Pushed = $false; Skipped = $null; Problem = $null }

    $upstream = git -C $Repo rev-parse --abbrev-ref '@{upstream}' 2>$null;
    if ($LASTEXITCODE -ne 0 -or -not $upstream)
    {
        $result.Skipped = 'no upstream';
        return $result;
    }

    $gitDir = git -C $Repo rev-parse --absolute-git-dir 2>$null;
    if ($LASTEXITCODE -ne 0 -or -not $gitDir)
    {
        $result.Skipped = 'no git dir';
        return $result;
    }

    # The stamp lives in .git so it is shared by every session on this machine and is never
    # a candidate for committing.
    $stampPath = Join-Path $gitDir.Trim() 'claude-plan-last-sync';
    if (-not $Force -and (Test-Path -LiteralPath $stampPath -PathType Leaf))
    {
        $raw = (Get-Content -Raw -LiteralPath $stampPath).Trim();
        [long]$last = 0;
        if ([long]::TryParse($raw, [ref]$last))
        {
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $last;
            if ($age -lt $IntervalSeconds)
            {
                $result.Skipped = "last synced $age s ago";
                return $result;
            }
        }
    }

    $result.Attempted = $true;
    # Stamp the attempt, not the success: a remote that is down would otherwise be retried
    # on every single write.
    Set-Content -LiteralPath $stampPath -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -NoNewline;

    $pull = git -C $Repo pull --rebase --quiet 2>&1;
    if ($LASTEXITCODE -ne 0)
    {
        # Never leave the repository mid-rebase; the next write has to find it clean.
        git -C $Repo rebase --abort 2>$null | Out-Null;
        $result.Problem = "git pull --rebase failed: $((@($pull) | Select-Object -Last 1))";
        return $result;
    }
    $result.Pulled = $true;

    $push = git -C $Repo push --quiet 2>&1;
    if ($LASTEXITCODE -ne 0)
    {
        $result.Problem = "git push failed: $((@($push) | Select-Object -Last 1))";
        return $result;
    }
    $result.Pushed = $true;

    return $result;
}

if (-not $PlansRepo)
{
    $context = & (Join-Path $PSScriptRoot 'Get-PlanContext.ps1') | ConvertFrom-Json;
    $PlansRepo = $context.PlansRepo;
}

$initialised = $false;

if (-not (Test-Path -LiteralPath $PlansRepo -PathType Container))
{
    if ($PSCmdlet.ShouldProcess($PlansRepo, 'create plans repository'))
    {
        New-Item -ItemType Directory -Path $PlansRepo -Force | Out-Null;
        $initialised = $true;
    }
}

$PlansRepo = if (Test-Path -LiteralPath $PlansRepo -PathType Container) { (Resolve-Path -LiteralPath $PlansRepo).Path } else { $PlansRepo }

$changed = @();
$committed = $false;
$commitSha = $null;
$brokeLock = $false;
$sync = [pscustomobject]@{ Attempted = $false; Pulled = $false; Pushed = $false; Skipped = 'not attempted'; Problem = $null };

if ($PSCmdlet.ShouldProcess($PlansRepo, "commit `"$Message`""))
{
    $lockPath = Join-Path $PlansRepo '.claude-plan.lock';
    $lock = Enter-PlanLock -Path $lockPath -TimeoutSeconds $LockTimeoutSeconds -StaleSeconds $StaleLockSeconds;
    $brokeLock = $lock.Broke;

    try
    {
        git -C $PlansRepo rev-parse --git-dir 2>$null | Out-Null;
        if ($LASTEXITCODE -ne 0)
        {
            git -C $PlansRepo init --quiet --initial-branch=main | Out-Host;
            if ($LASTEXITCODE -ne 0)
            {
                throw "git init failed in '$PlansRepo'.";
            }

            $initialised = $true;
        }

        git -C $PlansRepo add -A;
        if ($LASTEXITCODE -ne 0)
        {
            throw "git add failed in '$PlansRepo'.";
        }

        $changed = @(git -C $PlansRepo diff --cached --name-only | Where-Object { $_.Trim() });

        if ($changed.Count -gt 0)
        {
            git -C $PlansRepo commit --quiet -m $Message;
            if ($LASTEXITCODE -ne 0)
            {
                throw "git commit failed in '$PlansRepo'.";
            }

            $committed = $true;
            $commitSha = git -C $PlansRepo rev-parse HEAD;
        }

        if ($NoSync)
        {
            $sync.Skipped = 'disabled';
        }
        else
        {
            $sync = Sync-PlansRepo -Repo $PlansRepo -IntervalSeconds $SyncIntervalSeconds -Force:$SyncNow;
        }
    }
    finally
    {
        Remove-Item -LiteralPath $lockPath -Recurse -Force -ErrorAction SilentlyContinue;
    }
}

[pscustomobject]@{
    PlansRepo    = $PlansRepo
    Initialised  = $initialised
    Committed    = $committed
    Commit       = $commitSha
    Message      = $Message
    ChangedFiles = $changed
    BrokeLock    = $brokeLock
    Sync         = $sync
} | ConvertTo-Json -Depth 3
