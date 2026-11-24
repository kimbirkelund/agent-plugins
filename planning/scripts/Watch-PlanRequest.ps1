<#
.SYNOPSIS
    Watch the merge request or pull request of a branch and stream one JSON event per line
    for each thing that needs attention.

.DESCRIPTION
    Polls the forge every -IntervalSeconds for the request whose source branch is -Branch
    and prints every event that applies, each as one compressed JSON object on its own
    line, flushed as soon as it is written. Events, in the order a poll prints them:

      no-request       no request exists for the branch                 (ends the watch)
      merged           the request was merged                           (ends the watch)
      closed           the request was closed without merging           (ends the watch)
      conflict         the request conflicts with its target; once per head sha, and
                       again after the request is retargeted
      pipeline-failed  the head sha's pipeline or checks failed; once per pipeline id
      comments         review comments or discussion notes not emitted before

    A terminal event (the first three) is the only event its poll prints, and the script
    exits after printing it. A poll where nothing applies prints nothing; with -Once it
    prints an event `none` instead.

    Each event carries: Event, Request (Number, Url, State, Target, TargetIsDefault,
    HeadSha), Pipeline (State: none, running, passed or failed; Id; FailedJobs with Name,
    Id and Url), Conflicted, and Comments. Comments is filled only on the `comments` event
    and holds only the comments not emitted before (Id, Author, Body, Path, Line,
    Resolved, Url); every other event carries an empty Comments list.

    What was emitted is recorded in a state file, so a restarted watch does not repeat an
    event. An event is marked as emitted when it is printed. The state also records the
    request's target branch (Target). When the target differs from the recorded one, the
    conflicts already emitted are forgotten, so a request that is still conflicted after a
    retarget prints `conflict` again for the same head sha. A state file without Target
    only gets it recorded; nothing is forgotten.

    The tracker and its CLI come from Get-IssueContext.ps1, called as a command. GitHub is
    read with `gh pr view`, `gh api graphql --paginate` (inline review threads, every
    page; up to 100 comments per thread) and `gh repo view`. GitLab is read with
    `glab api` alone: the newest merge request whose source branch is -Branch, that
    request, its failed pipeline jobs, its discussions (`--paginate`, every page) and the
    project. On GitHub the pipeline id is the head sha, since checks have no id of their
    own.

    The script only reads the forge. It never posts, comments, resolves, approves or
    merges anything.

    A failed poll (network, CLI error) is written to stderr and the loop continues; with
    -Once the script exits 1 instead.

.PARAMETER Branch
    Source branch of the request to watch. Defaults to the checked-out branch.

.PARAMETER IntervalSeconds
    Seconds between polls. Defaults to 30.

.PARAMETER Once
    Poll once, then exit.

.PARAMETER StatePath
    File recording what was already emitted. Defaults to fnsh-state.json in the work
    tree's git directory (`git rev-parse --git-dir`), so it disappears with the worktree.

.OUTPUTS
    One single-line JSON object per event on stdout.

.EXAMPLE
    pwsh -File Watch-PlanRequest.ps1

.EXAMPLE
    pwsh -File Watch-PlanRequest.ps1 -Branch feature/login -Once
#>
[CmdletBinding()]
param(
    [string]$Branch,

    [ValidateRange(0, 86400)]
    [double]$IntervalSeconds = 30,

    [switch]$Once,

    [string]$StatePath
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

$issueContext = & (Join-Path $PSScriptRoot 'Get-IssueContext.ps1') | ConvertFrom-Json;

if ($issueContext.Tracker -eq 'unknown')
{
    throw "Cannot watch the request: the issue tracker of '$($issueContext.RepoRoot)' is unknown. Use an origin whose host part contains github or gitlab, or set issueTracker in the planning config.";
}
if (-not $issueContext.CliAvailable)
{
    throw "Cannot watch the request: the $($issueContext.Tracker) CLI '$($issueContext.Cli)' is not on PATH.";
}

$tracker = $issueContext.Tracker;
$cli = $issueContext.Cli;

if (-not $Branch)
{
    $Branch = (git rev-parse --abbrev-ref HEAD 2>$null);
    if ($LASTEXITCODE -ne 0 -or -not $Branch -or $Branch.Trim() -eq 'HEAD')
    {
        throw 'Cannot watch the request: no branch is checked out. Pass -Branch.';
    }
    $Branch = $Branch.Trim();
}

if (-not $StatePath)
{
    $gitDir = (git rev-parse --absolute-git-dir 2>$null);
    if ($LASTEXITCODE -ne 0 -or -not $gitDir)
    {
        throw 'Cannot watch the request: not inside a git work tree. Pass -StatePath.';
    }
    $StatePath = Join-Path $gitDir.Trim() 'fnsh-state.json';
}

function Invoke-Cli([string[]]$Arguments)
{
    $output = & $cli @Arguments 2>&1;
    $exitCode = $LASTEXITCODE;
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n";
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join "`n";

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout   = $stdout
        Stderr   = $stderr
    };
}

function Invoke-CliJson([string[]]$Arguments)
{
    $result = Invoke-Cli $Arguments;
    if ($result.ExitCode -ne 0)
    {
        throw "$cli $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.Stderr)$($result.Stdout)".Trim();
    }

    try
    {
        return ($result.Stdout | ConvertFrom-Json -NoEnumerate);
    }
    catch
    {
        throw "$cli $($Arguments -join ' ') printed output that is not JSON: $($result.Stdout)";
    }
}

function Invoke-CliNdjson([string[]]$Arguments)
{
    $result = Invoke-Cli $Arguments;
    if ($result.ExitCode -ne 0)
    {
        throw "$cli $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.Stderr)$($result.Stdout)".Trim();
    }

    try
    {
        return @($result.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json });
    }
    catch
    {
        throw "$cli $($Arguments -join ' ') printed output that is not JSON lines: $($result.Stdout)";
    }
}

function Get-Prop($Object, [string]$Name)
{
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }

    return $Object.$Name;
}

function New-Comment($Id, $Author, $Body, $Path, $Line, $Resolved, $Url)
{
    return [pscustomobject]@{
        Id       = "$Id"
        Author   = $Author
        Body     = $Body
        Path     = $Path
        Line     = $Line
        Resolved = $Resolved
        Url      = $Url
    };
}

function Get-GitHubSnapshot
{
    $fields = 'number,url,state,baseRefName,headRefOid,mergeable,statusCheckRollup,comments,reviews';
    $view = Invoke-Cli @('pr', 'view', $Branch, '--json', $fields);
    if ($view.ExitCode -ne 0)
    {
        if ("$($view.Stderr)" -match 'no pull requests found') { return $null }
        throw "gh pr view failed ($($view.ExitCode)): $($view.Stderr)$($view.Stdout)".Trim();
    }
    $pr = $view.Stdout | ConvertFrom-Json;

    $default = (Invoke-CliJson @('repo', 'view', '--json', 'defaultBranchRef')).defaultBranchRef.name;

    $state = switch ("$($pr.state)".ToUpperInvariant())
    {
        'MERGED' { 'merged' }
        'CLOSED' { 'closed' }
        default { 'open' }
    }

    $failedJobs = [System.Collections.Generic.List[object]]::new();
    $pending = $false;
    $checks = @(Get-Prop $pr 'statusCheckRollup' | Where-Object { $_ });
    foreach ($check in $checks)
    {
        if ((Get-Prop $check '__typename') -eq 'StatusContext')
        {
            $checkState = "$(Get-Prop $check 'state')".ToUpperInvariant();
            if ($checkState -in 'PENDING', 'EXPECTED') { $pending = $true }
            elseif ($checkState -in 'FAILURE', 'ERROR')
            {
                $failedJobs.Add([pscustomobject]@{ Name = Get-Prop $check 'context'; Id = $null; Url = Get-Prop $check 'targetUrl' });
            }
            continue;
        }

        if ("$(Get-Prop $check 'status')".ToUpperInvariant() -ne 'COMPLETED')
        {
            $pending = $true;
            continue;
        }
        if ("$(Get-Prop $check 'conclusion')".ToUpperInvariant() -in 'FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE')
        {
            $url = Get-Prop $check 'detailsUrl';
            $jobId = if ("$url" -match '/job/(\d+)') { $Matches[1] } else { $null }
            $failedJobs.Add([pscustomobject]@{ Name = Get-Prop $check 'name'; Id = $jobId; Url = $url });
        }
    }

    $pipelineState = if ($checks.Count -eq 0) { 'none' }
    elseif ($pending) { 'running' }
    elseif ($failedJobs.Count -gt 0) { 'failed' }
    else { 'passed' }

    $comments = [System.Collections.Generic.List[object]]::new();
    foreach ($note in @(Get-Prop $pr 'comments' | Where-Object { $_ }))
    {
        $comments.Add((New-Comment $note.id (Get-Prop $note.author 'login') $note.body $null $null $null (Get-Prop $note 'url')));
    }
    foreach ($review in @(Get-Prop $pr 'reviews' | Where-Object { $_ }))
    {
        if ([string]::IsNullOrWhiteSpace((Get-Prop $review 'body'))) { continue }
        $comments.Add((New-Comment $review.id (Get-Prop $review.author 'login') $review.body $null $null $null $pr.url));
    }

    if ("$($pr.url)" -notmatch '^https?://[^/]+/([^/]+)/([^/]+)/pull/\d+')
    {
        throw "Cannot read the repository from the pull request URL '$($pr.url)'.";
    }
    # --paginate walks the review threads through $endCursor; --slurp wraps the pages in
    # one JSON array. Comments within one thread are read up to the first 100.
    $query = 'query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved path line comments(first:100){nodes{databaseId body url path line author{login}}}}}}}}';
    $pages = Invoke-CliJson @('api', 'graphql', '--paginate', '--slurp', '-f', "query=$query", '-F', "owner=$($Matches[1])", '-F', "name=$($Matches[2])", '-F', "number=$($pr.number)");
    $threads = @($pages | ForEach-Object { $_ } | ForEach-Object { $_.data.repository.pullRequest.reviewThreads.nodes });
    foreach ($thread in @($threads | Where-Object { $_ }))
    {
        foreach ($note in @($thread.comments.nodes | Where-Object { $_ }))
        {
            $line = if ($null -ne (Get-Prop $note 'line')) { $note.line } else { Get-Prop $thread 'line' }
            $path = if (Get-Prop $note 'path') { $note.path } else { Get-Prop $thread 'path' }
            $comments.Add((New-Comment $note.databaseId (Get-Prop $note.author 'login') $note.body $path $line ([bool]$thread.isResolved) $note.url));
        }
    }

    return [pscustomobject]@{
        Request    = [pscustomobject]@{
            Number          = $pr.number
            Url             = $pr.url
            State           = $state
            Target          = $pr.baseRefName
            TargetIsDefault = ($pr.baseRefName -eq $default)
            HeadSha         = $pr.headRefOid
        }
        Pipeline   = [pscustomobject]@{
            State      = $pipelineState
            Id         = if ($pipelineState -eq 'none') { $null } else { $pr.headRefOid }
            FailedJobs = @($failedJobs)
        }
        Conflicted = ("$($pr.mergeable)".ToUpperInvariant() -eq 'CONFLICTING')
        Comments   = @($comments)
    };
}

function Get-GitLabSnapshot
{
    # A branch can carry several merge requests over time (an old closed one beside the
    # current one), so the newest request with this source branch is the one watched. An
    # empty list is the only signal for no-request.
    $branchQuery = [uri]::EscapeDataString($Branch);
    $requests = @(Invoke-CliJson @('api', "projects/:id/merge_requests?source_branch=$branchQuery&order_by=created_at&sort=desc&per_page=1") | ForEach-Object { $_ } | Where-Object { $_ });
    if ($requests.Count -eq 0) { return $null }
    $newest = $requests[0];

    $project = "projects/$($newest.project_id)";
    $mr = Invoke-CliJson @('api', "$project/merge_requests/$($newest.iid)");
    $default = (Invoke-CliJson @('api', $project)).default_branch;

    $state = switch ("$($mr.state)".ToLowerInvariant())
    {
        'merged' { 'merged' }
        'closed' { 'closed' }
        default { 'open' }
    }

    $headPipeline = Get-Prop $mr 'head_pipeline';
    $pipelineState = if ($null -eq $headPipeline) { 'none' }
    else
    {
        switch ("$($headPipeline.status)".ToLowerInvariant())
        {
            'success' { 'passed' }
            'failed' { 'failed' }
            { $_ -in 'canceled', 'skipped' } { 'none' }
            default { 'running' }
        }
    }

    $failedJobs = @();
    if ($pipelineState -eq 'failed')
    {
        $jobs = Invoke-CliJson @('api', "$project/pipelines/$($headPipeline.id)/jobs?scope[]=failed&per_page=100");
        $failedJobs = @($jobs | ForEach-Object { $_ } | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Name = $_.name; Id = $_.id; Url = Get-Prop $_ 'web_url' }
            });
    }

    $comments = [System.Collections.Generic.List[object]]::new();
    $discussions = Invoke-CliNdjson @('api', '--paginate', '--output', 'ndjson', "$project/merge_requests/$($mr.iid)/discussions?per_page=100");
    foreach ($discussion in @($discussions | ForEach-Object { $_ } | Where-Object { $_ }))
    {
        foreach ($note in @(Get-Prop $discussion 'notes' | Where-Object { $_ }))
        {
            if (Get-Prop $note 'system') { continue }
            $position = Get-Prop $note 'position';
            $path = Get-Prop $position 'new_path';
            if (-not $path) { $path = Get-Prop $position 'old_path' }
            $line = Get-Prop $position 'new_line';
            if ($null -eq $line) { $line = Get-Prop $position 'old_line' }
            $resolved = if (Get-Prop $note 'resolvable') { [bool](Get-Prop $note 'resolved') } else { $null }
            $comments.Add((New-Comment $note.id (Get-Prop (Get-Prop $note 'author') 'username') $note.body $path $line $resolved "$($mr.web_url)#note_$($note.id)"));
        }
    }

    return [pscustomobject]@{
        Request    = [pscustomobject]@{
            Number          = $mr.iid
            Url             = $mr.web_url
            State           = $state
            Target          = $mr.target_branch
            TargetIsDefault = ($mr.target_branch -eq $default)
            HeadSha         = $mr.sha
        }
        Pipeline   = [pscustomobject]@{
            State      = $pipelineState
            Id         = if ($null -eq $headPipeline) { $null } else { $headPipeline.id }
            FailedJobs = $failedJobs
        }
        Conflicted = [bool](Get-Prop $mr 'has_conflicts')
        Comments   = @($comments)
    };
}

function Read-State
{
    $state = [pscustomobject]@{ Conflicts = @(); Pipelines = @(); Comments = @(); Target = $null };
    if (Test-Path -LiteralPath $StatePath -PathType Leaf)
    {
        $saved = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json;
        foreach ($name in 'Conflicts', 'Pipelines', 'Comments')
        {
            $state.$name = @(Get-Prop $saved $name | Where-Object { $null -ne $_ } | ForEach-Object { "$_" });
        }
        $state.Target = Get-Prop $saved 'Target';
    }

    return $state;
}

function Save-State($State)
{
    $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath;
}

function Write-Event([string]$Name, $Snapshot, $Comments = @())
{
    $watchEvent = [pscustomobject]@{
        Event      = $Name
        Request    = if ($Snapshot) { $Snapshot.Request } else { $null }
        Pipeline   = if ($Snapshot) { $Snapshot.Pipeline } else { $null }
        Conflicted = if ($Snapshot) { $Snapshot.Conflicted } else { $false }
        Comments   = @($Comments)
    };
    [Console]::Out.WriteLine(($watchEvent | ConvertTo-Json -Depth 6 -Compress));
    [Console]::Out.Flush();
}

# Prints the events of one poll; returns $true when an event ends the watch.
function Invoke-Poll
{
    $snapshot = if ($tracker -eq 'github') { Get-GitHubSnapshot } else { Get-GitLabSnapshot }

    if ($null -eq $snapshot)
    {
        Write-Event 'no-request' $null;
        return [pscustomobject]@{ Ended = $true; Printed = $true };
    }
    if ($snapshot.Request.State -in 'merged', 'closed')
    {
        Write-Event $snapshot.Request.State $snapshot;
        return [pscustomobject]@{ Ended = $true; Printed = $true };
    }

    $state = Read-State;
    $printed = $false;

    # A retarget can create a conflict that the head sha alone does not show, so the
    # conflicts emitted for the old target no longer count. Target is stored on every poll
    # that finds a request, even when no event is printed.
    $target = "$($snapshot.Request.Target)";
    if ($null -ne $state.Target -and $state.Target -cne $target)
    {
        $state.Conflicts = @();
    }
    if ($state.Target -cne $target)
    {
        $state.Target = $target;
        Save-State $state;
    }

    $headSha = "$($snapshot.Request.HeadSha)";
    if ($snapshot.Conflicted -and $state.Conflicts -notcontains $headSha)
    {
        Write-Event 'conflict' $snapshot;
        $state.Conflicts = @($state.Conflicts) + $headSha;
        Save-State $state;
        $printed = $true;
    }

    $pipelineId = "$($snapshot.Pipeline.Id)";
    if ($snapshot.Pipeline.State -eq 'failed' -and $state.Pipelines -notcontains $pipelineId)
    {
        Write-Event 'pipeline-failed' $snapshot;
        $state.Pipelines = @($state.Pipelines) + $pipelineId;
        Save-State $state;
        $printed = $true;
    }

    $newComments = @($snapshot.Comments | Where-Object { $state.Comments -notcontains $_.Id });
    if ($newComments.Count -gt 0)
    {
        Write-Event 'comments' $snapshot $newComments;
        $state.Comments = @($state.Comments) + @($newComments | ForEach-Object { $_.Id });
        Save-State $state;
        $printed = $true;
    }

    return [pscustomobject]@{ Ended = $false; Printed = $printed };
}

while ($true)
{
    try
    {
        $result = Invoke-Poll;
    }
    catch
    {
        [Console]::Error.WriteLine("Watch-PlanRequest: poll failed: $($_.Exception.Message)");
        [Console]::Error.Flush();
        if ($Once) { exit 1 }
        Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000));
        continue;
    }

    if ($result.Ended) { exit 0 }
    if ($Once)
    {
        if (-not $result.Printed) { Write-Event 'none' $null }
        exit 0;
    }

    Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000));
}
