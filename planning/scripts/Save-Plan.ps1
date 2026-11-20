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

    Before the commit, the Markdown files that are part of it (added, modified or renamed)
    are formatted with prettier, using plan.prettierrc.json beside this script and ignoring
    any .editorconfig, so every plan is committed in one consistent shape whoever or
    whatever wrote it. Prose is wrapped at 80 columns. The header fields and the four
    `## How to execute plan` fields are list items, one per line, so wrapping cannot join
    them; a plan written in the old form (bare `Key: value` lines) is converted to list
    items by the save that commits it. That conversion is plain text work and does not need
    prettier. Formatting never fails the save: a missing prettier or a prettier that exits
    non-zero is reported in the output, and the save goes on: files prettier managed to
    format are committed formatted, the rest as they were written.

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

.PARAMETER NoFormat
    Commit the plans as written and do not run prettier.

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

    [switch]$NoSync,

    [switch]$NoFormat
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

function Convert-PlanHeader
{
    # Puts `- ` before the bare `Key: value` lines in a plan's header block and in its
    # `## How to execute plan` section. Never throws: returns one message per file it could
    # not read or write, and leaves that file as it was.
    param([string]$Repo, [string[]]$Files)

    $problems = @();
    foreach ($file in $Files)
    {
        try
        {
            $path = Join-Path $Repo $file;
            $bytes = [IO.File]::ReadAllBytes($path);
            $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF);
            $text = [Text.UTF8Encoding]::new($false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }));

            # Lines keep their own terminators, so CRLF and LF files come back as they were.
            $lines = [regex]::Split($text, '(?<=\n)');
            if ($lines.Count -eq 0 -or $lines[0] -notmatch '^#\s*Plan:') { continue }

            $region = 'header';
            $fence = $null;
            $edited = $false;
            for ($i = 1; $i -lt $lines.Count; $i++)
            {
                $body = $lines[$i] -replace '\r?\n$', '';

                if ($fence)
                {
                    if ($body -match '^\s{0,3}(`{3,}|~{3,})\s*$' -and $Matches[1][0] -eq $fence[0] -and $Matches[1].Length -ge $fence.Length) { $fence = $null }
                    continue;
                }

                if ($body -match '^\s{0,3}(`{3,}|~{3,})')
                {
                    $fence = $Matches[1];
                    continue;
                }

                if ($body -match '^## ')
                {
                    $region = if ($body -match '^##\s+How to execute plan\s*$') { 'execute' } else { $null };
                    continue;
                }

                if ($region -and $body -match '^[A-Z][A-Za-z]*:(\s|$)')
                {
                    $lines[$i] = "- $($lines[$i])";
                    $edited = $true;
                }
            }

            if ($edited)
            {
                $out = [Text.UTF8Encoding]::new($false).GetBytes(($lines -join ''));
                if ($bom) { $out = [byte[]]@(0xEF, 0xBB, 0xBF) + $out }
                [IO.File]::WriteAllBytes($path, $out);
            }
        }
        catch
        {
            $problems += "plan header conversion failed for '$file': $($_.Exception.Message)";
        }
    }

    return $problems;
}

function Format-PlanFile
{
    param([string]$Repo, [string[]]$Files, [string]$Config, [switch]$Disabled)

    $result = [pscustomobject]@{ Attempted = $false; Formatted = @(); Skipped = $null; Problem = $null }

    if ($Disabled)
    {
        $result.Skipped = 'disabled';
        return $result;
    }

    if (@($Files).Count -eq 0)
    {
        $result.Skipped = 'no markdown changes';
        return $result;
    }

    # The "before" bytes come first, so Formatted covers the header conversion too.
    $before = @{};
    foreach ($file in $Files)
    {
        try { $before[$file] = [IO.File]::ReadAllBytes((Join-Path $Repo $file)) }
        catch { $before[$file] = $null }
    }

    $convertProblems = @(Convert-PlanHeader -Repo $Repo -Files $Files);
    if ($convertProblems.Count -gt 0) { $result.Problem = $convertProblems -join '; ' }

    $changedFiles = {
        @($Files | Where-Object {
                $was = $before[$_];
                if ($null -eq $was) { return $false }
                try { -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$was, [byte[]][IO.File]::ReadAllBytes((Join-Path $Repo $_))) }
                catch { $false }
            })
    };

    $prettier = Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1;
    if (-not $prettier)
    {
        $result.Skipped = 'prettier not found';
        $result.Formatted = @(& $changedFiles);
        return $result;
    }

    $result.Attempted = $true;
    try
    {
        Push-Location -LiteralPath $Repo;
        try
        {
            $output = & $prettier.Source --write --no-editorconfig --config $Config @Files 2>&1;
            $exit = $LASTEXITCODE;
        }
        finally
        {
            Pop-Location;
        }

        if ($exit -ne 0)
        {
            $last = @($output | ForEach-Object { "$_" } | Where-Object { $_.Trim() }) | Select-Object -Last 1;
            $result.Problem = (@($result.Problem, "prettier exited $($exit): $last") | Where-Object { $_ }) -join '; ';
        }
    }
    catch
    {
        $result.Problem = (@($result.Problem, "prettier failed: $($_.Exception.Message)") | Where-Object { $_ }) -join '; ';
    }

    $result.Formatted = @(& $changedFiles);

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
$format = [pscustomobject]@{ Attempted = $false; Formatted = @(); Skipped = 'not attempted'; Problem = $null };
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

        $markdown = @((@(git -C $PlansRepo diff --cached --name-only --diff-filter=AMR -z -- '*.md') -join "`n") -split "`0" | Where-Object { $_ });
        $format = Format-PlanFile -Repo $PlansRepo -Files $markdown -Config (Join-Path $PSScriptRoot 'plan.prettierrc.json') -Disabled:$NoFormat;
        if ($format.Attempted -or @($format.Formatted).Count -gt 0)
        {
            git -C $PlansRepo add -A;
            if ($LASTEXITCODE -ne 0)
            {
                throw "git add failed in '$PlansRepo'.";
            }
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
    Format       = $format
    Sync         = $sync
} | ConvertTo-Json -Depth 3
