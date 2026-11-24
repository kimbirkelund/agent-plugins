BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Watch-PlanRequest.ps1';
    $script:RealGit = (Get-Command git).Source;
    $script:Pwsh = (Get-Process -Id $PID).Path;

    # The stub CLI matches its arguments against these shell patterns, most specific first,
    # and answers with the canned files of the matching key. A key answers with
    # KEY.N.out on its Nth call when that file exists, else with KEY.out; KEY.N.rc or
    # KEY.rc holds its exit code and KEY.N.err or KEY.err what it writes to stderr.
    $script:StubKeys = @{
        gh   = @(
            @{ Pattern = 'pr view*'; Key = 'pr' }
            @{ Pattern = 'api graphql*'; Key = 'threads' }
            @{ Pattern = 'repo view*'; Key = 'repo' }
        )
        glab = @(
            @{ Pattern = 'api projects/:id/merge_requests?*'; Key = 'mrs' }
            @{ Pattern = 'api --paginate --output ndjson projects/*/discussions*'; Key = 'discussions' }
            @{ Pattern = 'api projects/*/jobs*'; Key = 'jobs' }
            @{ Pattern = 'api projects/*/merge_requests/*'; Key = 'mr' }
            @{ Pattern = 'api projects/*'; Key = 'project' }
        )
    };

    function New-Fixture
    {
        param(
            [ValidateSet('github', 'gitlab', 'unknown')]
            [string]$Forge,

            [switch]$NoCli
        )

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $configHome = Join-Path $base 'config';
        $bin = Join-Path $base 'bin';
        $responses = Join-Path $base 'responses';

        foreach ($dir in $repoRoot, $configHome, $bin, $responses)
        {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null;
        }
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');

        git -C $repoRoot init --quiet --initial-branch=main;
        git -C $repoRoot config user.name 'Test User';
        git -C $repoRoot config user.email 'test@example.com';
        git -C $repoRoot config commit.gpgsign false;
        git -C $repoRoot add -A;
        git -C $repoRoot commit --quiet -m 'initial';
        git -C $repoRoot switch --quiet -c feature/login;

        $origin = switch ($Forge)
        {
            'github' { 'git@github.com:group/widget.git' }
            'gitlab' { 'git@gitlab.com:group/widget.git' }
            default { 'git@git.example.com:group/widget.git' }
        }
        git -C $repoRoot remote add origin $origin;

        New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'git') -Target $script:RealGit | Out-Null;
        $cli = if ($Forge -eq 'gitlab') { 'glab' } else { 'gh' }
        if (-not $NoCli -and $Forge -ne 'unknown')
        {
            $cases = foreach ($entry in $script:StubKeys[$cli])
            {
                "  $($entry.Pattern -replace ' ', '\ ')) key=$($entry.Key) ;;"
            }
            $stub = @(
                '#!/bin/sh'
                "dir='$responses'"
                'case "$*" in'
                $cases
                '  *) echo "stub: unexpected arguments: $*" >&2; exit 99 ;;'
                'esac'
                'n=0'
                '[ -f "$dir/$key.count" ] && n=$(/bin/cat "$dir/$key.count")'
                'n=$((n + 1))'
                'echo "$n" > "$dir/$key.count"'
                'echo "$*" >> "$dir/calls.log"'
                'if [ -f "$dir/$key.$n.out" ]; then /bin/cat "$dir/$key.$n.out"; elif [ -f "$dir/$key.out" ]; then /bin/cat "$dir/$key.out"; fi'
                'if [ -f "$dir/$key.$n.err" ]; then /bin/cat "$dir/$key.$n.err" >&2; elif [ -f "$dir/$key.err" ]; then /bin/cat "$dir/$key.err" >&2; fi'
                'rc=0'
                'if [ -f "$dir/$key.$n.rc" ]; then rc=$(/bin/cat "$dir/$key.$n.rc"); elif [ -f "$dir/$key.rc" ]; then rc=$(/bin/cat "$dir/$key.rc"); fi'
                'exit "$rc"'
            ) -join "`n";
            $stubPath = Join-Path $bin $cli;
            $stub | Set-Content -LiteralPath $stubPath -NoNewline;
            & chmod +x $stubPath;
        }

        return [pscustomobject]@{
            Base       = $base
            CodeRoot   = $codeRoot
            RepoRoot   = $repoRoot
            ConfigHome = $configHome
            Bin        = $bin
            Responses  = $responses
            StatePath  = Join-Path $base 'state.json'
        }
    }

    function Set-Response($Fixture, [string]$Key, $Value, [int]$Call = 0, [int]$ExitCode = 0, [string]$Stderr)
    {
        $name = if ($Call -gt 0) { "$Key.$Call.out" } else { "$Key.out" }
        $suffix = if ($Call -gt 0) { "$Key.$Call" } else { $Key }
        $text = if ($Value -is [string]) { $Value } else { ConvertTo-Json -InputObject $Value -Depth 20 }
        $text | Set-Content -LiteralPath (Join-Path $Fixture.Responses $name);
        if ($ExitCode -ne 0) { "$ExitCode" | Set-Content -LiteralPath (Join-Path $Fixture.Responses "$suffix.rc") }
        if ($Stderr) { $Stderr | Set-Content -LiteralPath (Join-Path $Fixture.Responses "$suffix.err") }
    }

    function New-PullRequest
    {
        param(
            [string]$State = 'OPEN',
            [string]$Sha = 'aaa111',
            [string]$Mergeable = 'MERGEABLE',
            [object[]]$Checks = @(),
            [object[]]$Comments = @(),
            [object[]]$Reviews = @(),
            [string]$Base = 'main',
            [string]$MergeState = 'CLEAN'
        )

        return [ordered]@{
            number            = 7
            url               = 'https://github.com/group/widget/pull/7'
            state             = $State
            baseRefName       = $Base
            headRefOid        = $Sha
            mergeable         = $Mergeable
            mergeStateStatus  = $MergeState
            statusCheckRollup = @($Checks)
            comments          = @($Comments)
            reviews           = @($Reviews)
        };
    }

    function New-Threads([object[]]$Threads = @())
    {
        # gh api graphql --paginate --slurp prints an array of pages; this is one page.
        return , @(@{ data = @{ repository = @{ pullRequest = @{ reviewThreads = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @($Threads) } } } } });
    }

    function New-MergeRequest
    {
        param(
            [string]$State = 'opened',
            [string]$Sha = 'bbb222',
            [bool]$Conflicts = $false,
            $Pipeline = $null,
            [string]$Target = 'main',
            [string]$DetailedMergeStatus = 'mergeable'
        )

        return [ordered]@{
            iid                   = 12
            project_id            = 345
            web_url               = 'https://gitlab.com/group/widget/-/merge_requests/12'
            state                 = $State
            target_branch         = $Target
            source_branch         = 'feature/login'
            sha                   = $Sha
            has_conflicts         = $Conflicts
            detailed_merge_status = $DetailedMergeStatus
            head_pipeline         = $Pipeline
        };
    }

    function Set-GitHub($Fixture, $PullRequest, $Threads = (New-Threads), [string]$DefaultBranch = 'main')
    {
        Set-Response $Fixture 'pr' $PullRequest;
        Set-Response $Fixture 'threads' $Threads;
        Set-Response $Fixture 'repo' @{ defaultBranchRef = @{ name = $DefaultBranch } };
    }

    function Set-GitLab($Fixture, $MergeRequest, [object[]]$Discussions = @(), [object[]]$Jobs = @(), [string]$DefaultBranch = 'main')
    {
        Set-Response $Fixture 'mrs' (ConvertTo-Json -InputObject @(@{ iid = $MergeRequest.iid; project_id = $MergeRequest.project_id }) -Depth 3);
        Set-Response $Fixture 'mr' $MergeRequest;
        Set-Response $Fixture 'discussions' (@($Discussions | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 10 -Compress }) -join "`n");
        Set-Response $Fixture 'jobs' (ConvertTo-Json -InputObject @($Jobs) -Depth 10);
        Set-Response $Fixture 'project' @{ id = 345; default_branch = $DefaultBranch };
    }

    function Invoke-Watch($Fixture, [string[]]$Extra = @('-Once'), [switch]$DefaultState)
    {
        $scriptArguments = @($Extra);
        if (-not $DefaultState) { $scriptArguments += @('-StatePath', $Fixture.StatePath) }

        # -Command rather than -File, so the child renders an uncaught error plain and
        # unwrapped: the default view colours it and wraps it at a console width that differs
        # between hosts. The exit code is the one -File would give.
        $quoted = @($scriptArguments | ForEach-Object { if ($_ -match '^-\w+$') { $_ } else { "'" + ($_ -replace "'", "''") + "'" } });
        $command = "`$ErrorView = 'NormalView'; `$PSStyle.OutputRendering = 'PlainText'; `$global:LASTEXITCODE = 0; " +
        "& '$($script:ScriptPath -replace "'", "''")' $($quoted -join ' '); exit `$LASTEXITCODE";
        $arguments = @('-NoProfile', '-NonInteractive', '-Command', $command);

        # A child process with its own environment and working directory, killed after a
        # timeout so a watch that never ends fails the test instead of hanging the run.
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh);
        foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.WorkingDirectory = $Fixture.RepoRoot;
        $startInfo.RedirectStandardOutput = $true;
        $startInfo.RedirectStandardError = $true;
        $startInfo.UseShellExecute = $false;
        $startInfo.Environment['PATH'] = $Fixture.Bin;
        $startInfo.Environment['XDG_CONFIG_HOME'] = $Fixture.ConfigHome;
        $startInfo.Environment['__CODE_ROOT'] = $Fixture.CodeRoot;
        $startInfo.Environment.Remove('CLAUDE_PLANS_REPO') | Out-Null;

        $process = [System.Diagnostics.Process]::Start($startInfo);
        $stdoutTask = $process.StandardOutput.ReadToEndAsync();
        $stderrTask = $process.StandardError.ReadToEndAsync();
        if (-not $process.WaitForExit(30000))
        {
            $process.Kill($true);
            throw 'Watch-PlanRequest did not exit within 30 seconds.';
        }
        $process.WaitForExit();

        $lines = @($stdoutTask.Result -split "`r?`n" | Where-Object { $_.Trim() });
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Lines    = $lines
            Events   = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
            Stderr   = $stderrTask.Result
        }
    }

    function Get-EventNames($Result)
    {
        return @($Result.Events | ForEach-Object { $_.Event });
    }
}

Describe 'Watch-PlanRequest' {

    Context 'GitHub events' {

        It 'prints no-request when the branch has no pull request' {
            $f = New-Fixture -Forge github;
            Set-Response $f 'pr' '' -ExitCode 1 -Stderr 'no pull requests found for branch "feature/login"';

            $result = Invoke-Watch $f;

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('no-request');
            $result.Events[0].Request | Should -BeNullOrEmpty;
        }

        It 'prints merged and reads the branch it was given' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -State MERGED);

            $result = Invoke-Watch $f @('-Once', '-Branch', 'other/branch');

            Get-EventNames $result | Should -Be @('merged');
            $result.Events[0].Request.Number | Should -Be 7;
            $result.Events[0].Request.State | Should -Be 'merged';
            Get-Content -LiteralPath (Join-Path $f.Responses 'calls.log') | Select-Object -First 1 | Should -BeLike 'pr view other/branch --json *';
        }

        It 'prints closed' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -State CLOSED);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('closed');
        }

        It 'prints conflict with the request fields' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Sha 'abc123');

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict');
            $result.Lines.Count | Should -Be 1;
            $event = $result.Events[0];
            $event.Conflicted | Should -BeTrue;
            $event.Request.Url | Should -Be 'https://github.com/group/widget/pull/7';
            $event.Request.State | Should -Be 'open';
            $event.Request.Target | Should -Be 'main';
            $event.Request.TargetIsDefault | Should -BeTrue;
            $event.Request.HeadSha | Should -Be 'abc123';
            $event.Pipeline.State | Should -Be 'none';
            @($event.Comments).Count | Should -Be 0;
        }

        It 'reports TargetIsDefault false when the target is not the default branch' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Base 'release');

            (Invoke-Watch $f).Events[0].Request.TargetIsDefault | Should -BeFalse;
        }

        It 'prints pipeline-failed with the failed checks once the checks are done' {
            $f = New-Fixture -Forge github;
            $checks = @(
                @{ __typename = 'CheckRun'; name = 'lint'; status = 'COMPLETED'; conclusion = 'SUCCESS'; detailsUrl = 'https://github.com/group/widget/actions/runs/1/job/10' }
                @{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'https://github.com/group/widget/actions/runs/1/job/11' }
                @{ __typename = 'StatusContext'; context = 'ci/legacy'; state = 'ERROR'; targetUrl = 'https://ci.example.com/5' }
            );
            Set-GitHub $f (New-PullRequest -Checks $checks -Sha 'sha9');

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('pipeline-failed');
            $pipeline = $result.Events[0].Pipeline;
            $pipeline.State | Should -Be 'failed';
            $pipeline.Id | Should -Be 'sha9';
            @($pipeline.FailedJobs).Count | Should -Be 2;
            $pipeline.FailedJobs[0].Name | Should -Be 'test';
            $pipeline.FailedJobs[0].Id | Should -Be '11';
            $pipeline.FailedJobs[0].Url | Should -Be 'https://github.com/group/widget/actions/runs/1/job/11';
            $pipeline.FailedJobs[1].Name | Should -Be 'ci/legacy';
        }

        It 'reports running and no event while a check is still in progress' {
            $f = New-Fixture -Forge github;
            $checks = @(
                @{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'u1' }
                @{ __typename = 'CheckRun'; name = 'build'; status = 'IN_PROGRESS'; conclusion = ''; detailsUrl = 'u2' }
            );
            Set-GitHub $f (New-PullRequest -Checks $checks);

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('none');
        }

        It 'prints comments from conversation, reviews and inline threads' {
            $f = New-Fixture -Forge github;
            $pr = New-PullRequest `
                -Comments @(@{ id = 'IC_1'; author = @{ login = 'ann' }; body = 'General note'; url = 'https://github.com/group/widget/pull/7#issuecomment-1' }) `
                -Reviews @(
                @{ id = 'PRR_1'; author = @{ login = 'bob' }; body = 'Please rework'; state = 'CHANGES_REQUESTED' }
                @{ id = 'PRR_2'; author = @{ login = 'bob' }; body = ''; state = 'COMMENTED' }
            );
            $threads = New-Threads @(
                @{ isResolved = $true; path = 'src/a.ps1'; line = 4; comments = @{ nodes = @(
                            @{ databaseId = 901; body = 'Rename this'; url = 'https://github.com/group/widget/pull/7#discussion_r901'; path = 'src/a.ps1'; line = 4; author = @{ login = 'cid' } }
                        )
                    }
                }
            );
            Set-GitHub $f $pr $threads;

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('comments');
            $comments = @($result.Events[0].Comments);
            $comments.Count | Should -Be 3;
            $comments[0].Id | Should -Be 'IC_1';
            $comments[0].Author | Should -Be 'ann';
            $comments[0].Body | Should -Be 'General note';
            $comments[1].Id | Should -Be 'PRR_1';
            $comments[2].Id | Should -Be '901';
            $comments[2].Path | Should -Be 'src/a.ps1';
            $comments[2].Line | Should -Be 4;
            $comments[2].Resolved | Should -BeTrue;
            $comments[2].Url | Should -Be 'https://github.com/group/widget/pull/7#discussion_r901';
            Get-Content -LiteralPath (Join-Path $f.Responses 'calls.log') | Where-Object { $_ -like 'api graphql*' } | Should -BeLike '*owner=group*name=widget*number=7*';
        }
    }

    Context 'GitLab events' {

        It 'prints no-request when the branch has no merge request' {
            $f = New-Fixture -Forge gitlab;
            Set-Response $f 'mrs' '[]';

            Get-EventNames (Invoke-Watch $f) | Should -Be @('no-request');
            Get-Content -LiteralPath (Join-Path $f.Responses 'calls.log') | Should -Be @('api projects/:id/merge_requests?source_branch=feature%2Flogin&order_by=created_at&sort=desc&per_page=1');
        }

        It 'watches the newest of several merge requests for one branch' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true);
            Set-Response $f 'mrs' (ConvertTo-Json -InputObject @(@{ iid = 13; project_id = 345; state = 'opened' }, @{ iid = 12; project_id = 345; state = 'closed' }));

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
            Get-Content -LiteralPath (Join-Path $f.Responses 'calls.log') | Should -Contain 'api projects/345/merge_requests/13';
        }

        It 'reads a merge request whose description holds the not-found phrase as a request' {
            $f = New-Fixture -Forge gitlab;
            $mr = New-MergeRequest -Conflicts $true;
            $mr['description'] = 'Fixes: no open merge request available for "feature/login"';
            Set-GitLab $f $mr;

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
        }

        It 'prints merged' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -State merged);

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('merged');
            $result.Events[0].Request.Number | Should -Be 12;
        }

        It 'prints closed' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -State closed);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('closed');
        }

        It 'prints conflict with the request fields' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'def456' -Target 'develop') -DefaultBranch 'main';

            $event = (Invoke-Watch $f).Events[0];

            $event.Event | Should -Be 'conflict';
            $event.Conflicted | Should -BeTrue;
            $event.Request.Url | Should -Be 'https://gitlab.com/group/widget/-/merge_requests/12';
            $event.Request.State | Should -Be 'open';
            $event.Request.Target | Should -Be 'develop';
            $event.Request.TargetIsDefault | Should -BeFalse;
            $event.Request.HeadSha | Should -Be 'def456';
        }

        It 'prints pipeline-failed with the failed jobs' {
            $f = New-Fixture -Forge gitlab;
            $pipeline = @{ id = 555; status = 'failed'; web_url = 'https://gitlab.com/group/widget/-/pipelines/555' };
            $jobs = @(@{ id = 77; name = 'unit-tests'; web_url = 'https://gitlab.com/group/widget/-/jobs/77' });
            Set-GitLab $f (New-MergeRequest -Pipeline $pipeline) -Jobs $jobs;

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('pipeline-failed');
            $result.Events[0].Pipeline.State | Should -Be 'failed';
            $result.Events[0].Pipeline.Id | Should -Be 555;
            $result.Events[0].Pipeline.FailedJobs[0].Name | Should -Be 'unit-tests';
            $result.Events[0].Pipeline.FailedJobs[0].Id | Should -Be 77;
            $result.Events[0].Pipeline.FailedJobs[0].Url | Should -Be 'https://gitlab.com/group/widget/-/jobs/77';
        }

        It 'maps a running pipeline to running and prints nothing' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Pipeline @{ id = 556; status = 'running' });

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('none');
            Test-Path (Join-Path $f.Responses 'jobs.count') | Should -BeFalse;
        }

        It 'prints comments from discussions and skips system notes' {
            $f = New-Fixture -Forge gitlab;
            $discussions = @(
                @{ id = 'd1'; notes = @(
                        @{ id = 1001; body = 'Fix the typo'; system = $false; resolvable = $true; resolved = $false; author = @{ username = 'dee' }; position = @{ new_path = 'README.md'; new_line = 9 } }
                        @{ id = 1002; body = 'added 1 commit'; system = $true; resolvable = $false; author = @{ username = 'dee' } }
                    )
                }
                @{ id = 'd2'; notes = @(
                        @{ id = 1003; body = 'Looks good'; system = $false; resolvable = $false; author = @{ username = 'eve' }; position = $null }
                    )
                }
            );
            Set-GitLab $f (New-MergeRequest) -Discussions $discussions;

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('comments');
            $comments = @($result.Events[0].Comments);
            $comments.Count | Should -Be 2;
            $comments[0].Id | Should -Be '1001';
            $comments[0].Author | Should -Be 'dee';
            $comments[0].Path | Should -Be 'README.md';
            $comments[0].Line | Should -Be 9;
            $comments[0].Resolved | Should -BeFalse;
            $comments[0].Url | Should -Be 'https://gitlab.com/group/widget/-/merge_requests/12#note_1001';
            $comments[1].Id | Should -Be '1003';
            $comments[1].Resolved | Should -BeNullOrEmpty;
        }
    }

    Context 'ordering and state' {

        It 'prints conflict, pipeline-failed and comments in that order in one poll' {
            $f = New-Fixture -Forge gitlab;
            $discussions = @(@{ id = 'd1'; notes = @(@{ id = 1; body = 'x'; system = $false; author = @{ username = 'a' } }) });
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Pipeline @{ id = 9; status = 'failed' }) -Discussions $discussions -Jobs @(@{ id = 3; name = 'j' });

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict', 'pipeline-failed', 'comments');
            @($result.Events[0].Comments).Count | Should -Be 0;
            @($result.Events[2].Comments).Count | Should -Be 1;
        }

        It 'prints two events in one poll' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'u' });
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Checks $checks);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict', 'pipeline-failed');
        }

        It 'lets a terminal event suppress every other event' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'u' });
            $comments = @(@{ id = 'IC_1'; author = @{ login = 'ann' }; body = 'hi'; url = 'u' });
            Set-GitHub $f (New-PullRequest -State MERGED -Mergeable CONFLICTING -Checks $checks -Comments $comments);

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('merged');
            Test-Path $f.StatePath | Should -BeFalse;
        }

        It 'does not repeat an event already emitted' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'u' });
            $comments = @(@{ id = 'IC_1'; author = @{ login = 'ann' }; body = 'hi'; url = 'u' });
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Checks $checks -Comments $comments);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict', 'pipeline-failed', 'comments');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'prints only the comments not emitted before' {
            $f = New-Fixture -Forge github;
            $first = @{ id = 'IC_1'; author = @{ login = 'ann' }; body = 'one'; url = 'u' };
            Set-GitHub $f (New-PullRequest -Comments @($first));
            Invoke-Watch $f | Out-Null;

            Set-GitHub $f (New-PullRequest -Comments @($first, @{ id = 'IC_2'; author = @{ login = 'ann' }; body = 'two'; url = 'u' }));
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('comments');
            @($result.Events[0].Comments).Id | Should -Be @('IC_2');
        }

        It 'prints behind for a GitHub request whose merge state is BEHIND' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'abc123');

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('behind');
            $result.Events[0].Behind | Should -BeTrue;
            $result.Events[0].Conflicted | Should -BeFalse;
            $result.Events[0].Request.HeadSha | Should -Be 'abc123';
        }

        It 'prints nothing for GitHub merge states CLEAN and UNKNOWN' {
            foreach ($mergeState in 'CLEAN', 'UNKNOWN')
            {
                $f = New-Fixture -Forge github;
                Set-GitHub $f (New-PullRequest -MergeState $mergeState);

                Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
            }
        }

        It 'prints only conflict for a GitHub request that is conflicting and DIRTY' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -MergeState DIRTY);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
        }

        It 'prints only conflict for a GitHub request that is conflicting and BEHIND' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -MergeState BEHIND);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'prints only conflict for a GitLab request that has conflicts and needs a rebase' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -DetailedMergeStatus need_rebase);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'prints behind for a GitLab request that needs a rebase' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -DetailedMergeStatus need_rebase);

            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('behind');
            $result.Events[0].Behind | Should -BeTrue;
        }

        It 'does not report the same behind head sha twice' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'same');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('behind');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'reports behind again for a new head sha that is behind' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'one');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('behind');

            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'two');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('behind');
            $result.Events[0].Request.HeadSha | Should -Be 'two';
        }

        It 're-reports behind after a retarget with the same head sha' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'same' -Base 'release') -DefaultBranch 'main';
            Get-EventNames (Invoke-Watch $f) | Should -Be @('behind');

            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'same' -Base 'main');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('behind');
            $result.Events[0].Request.Target | Should -Be 'main';
        }

        It 're-arms conflict for a new head sha' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'one');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');

            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'two');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict');
            $result.Events[0].Request.HeadSha | Should -Be 'two';
        }

        It 're-arms conflict after a GitHub retarget with the same head sha' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Sha 'same' -Base 'release') -DefaultBranch 'main';
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');

            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Sha 'same' -Base 'main');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict');
            $result.Events[0].Request.Target | Should -Be 'main';
            $result.Events[0].Request.TargetIsDefault | Should -BeTrue;
        }

        It 're-arms conflict after a GitLab retarget with the same head sha' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same' -Target 'release');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');

            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same' -Target 'main');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict');
            $result.Events[0].Request.Target | Should -Be 'main';
            $result.Events[0].Request.TargetIsDefault | Should -BeTrue;
        }

        It 're-arms conflict after a retarget from the default branch to another branch' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same' -Target 'main');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');

            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same' -Target 'release');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('conflict');
            $result.Events[0].Request.Target | Should -Be 'release';
            $result.Events[0].Request.TargetIsDefault | Should -BeFalse;
        }

        It 'keeps conflict suppressed for the same target and head sha' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'reads a state file without Behinds and emits behind once' {
            $f = New-Fixture -Forge github;
            @{ Conflicts = @(); Pipelines = @(); Comments = @(); Target = 'main' } | ConvertTo-Json | Set-Content -LiteralPath $f.StatePath;
            Set-GitHub $f (New-PullRequest -MergeState BEHIND -Sha 'same');

            Get-EventNames (Invoke-Watch $f) | Should -Be @('behind');
            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');
        }

        It 'records Target without emitting when the state file has none' {
            $f = New-Fixture -Forge gitlab;
            @{ Conflicts = @('same'); Pipelines = @(); Comments = @() } | ConvertTo-Json | Set-Content -LiteralPath $f.StatePath;
            Set-GitLab $f (New-MergeRequest -Conflicts $true -Sha 'same' -Target 'main');

            Get-EventNames (Invoke-Watch $f) | Should -Be @('none');

            (Get-Content -Raw $f.StatePath | ConvertFrom-Json).Target | Should -Be 'main';
        }

        It 'does not repeat pipeline-failed or comments after a retarget' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'u' });
            $comments = @(@{ id = 'IC_1'; author = @{ login = 'ann' }; body = 'hi'; url = 'u' });
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Sha 'same' -Base 'release' -Checks $checks -Comments $comments);
            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict', 'pipeline-failed', 'comments');

            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Sha 'same' -Base 'main' -Checks $checks -Comments $comments);

            Get-EventNames (Invoke-Watch $f) | Should -Be @('conflict');
        }

        It 'prints none and stores the new Target after a retarget without conflict' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Base 'release');
            Invoke-Watch $f | Out-Null;

            Set-GitHub $f (New-PullRequest -Base 'main');
            $result = Invoke-Watch $f;

            Get-EventNames $result | Should -Be @('none');
            (Get-Content -Raw $f.StatePath | ConvertFrom-Json).Target | Should -Be 'main';
        }

        It 'keeps its state in the git directory by default' {
            $f = New-Fixture -Forge gitlab;
            Set-GitLab $f (New-MergeRequest -Conflicts $true);

            Get-EventNames (Invoke-Watch $f -DefaultState) | Should -Be @('conflict');

            $statePath = Join-Path $f.RepoRoot '.git/fnsh-state.json';
            Test-Path $statePath | Should -BeTrue;
            (Get-Content -Raw $statePath | ConvertFrom-Json).Conflicts | Should -Be @('bbb222');
            Get-EventNames (Invoke-Watch $f -DefaultState) | Should -Be @('none');
        }

        It 'prints none when nothing applies' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'SUCCESS'; detailsUrl = 'u' });
            Set-GitHub $f (New-PullRequest -Checks $checks);

            $result = Invoke-Watch $f;

            $result.ExitCode | Should -Be 0;
            $result.Lines.Count | Should -Be 1;
            $result.Events[0].Event | Should -Be 'none';
        }
    }

    Context 'failures' {

        It 'writes a failed poll to stderr and prints no event' {
            $f = New-Fixture -Forge github;
            Set-Response $f 'pr' '' -ExitCode 1 -Stderr 'error connecting to api.github.com';

            $result = Invoke-Watch $f;

            $result.ExitCode | Should -Be 1;
            $result.Lines.Count | Should -Be 0;
            $result.Stderr | Should -Match 'poll failed.*error connecting to api\.github\.com';
        }

        It 'throws for an unknown tracker' {
            $f = New-Fixture -Forge unknown;

            $result = Invoke-Watch $f;

            $result.ExitCode | Should -Not -Be 0;
            $result.Lines.Count | Should -Be 0;
            $result.Stderr | Should -Match '(?s)issue tracker of.*is unknown';
            $result.Stderr | Should -Match 'host part contains github or gitlab';
        }

        It 'throws when the CLI is missing' {
            $f = New-Fixture -Forge gitlab -NoCli;

            $result = Invoke-Watch $f;

            $result.ExitCode | Should -Not -Be 0;
            $result.Stderr | Should -Match "gitlab CLI 'glab' is not on PATH";
        }
    }

    Context 'the loop' {

        It 'polls again after the interval and exits after printing merged' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest);
            Set-Response $f 'pr' (New-PullRequest -State MERGED) -Call 2;

            $result = Invoke-Watch $f @('-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('merged');
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '2';
        }

        It 'writes a failed poll to stderr, keeps polling and exits after printing merged' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -State MERGED);
            Set-Response $f 'pr' '' -Call 1 -ExitCode 1 -Stderr 'error connecting to api.github.com';

            $result = Invoke-Watch $f @('-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('merged');
            $result.Stderr | Should -Match 'poll failed.*error connecting to api\.github\.com';
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '2';
        }
    }

    Context 'until an event' {

        It 'exits after a poll that prints one non-terminal event' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING);

            $result = Invoke-Watch $f @('-UntilEvent', '-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('conflict');
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '1';
        }

        It 'prints every event of the poll before it exits' {
            $f = New-Fixture -Forge github;
            $checks = @(@{ __typename = 'CheckRun'; name = 'test'; status = 'COMPLETED'; conclusion = 'FAILURE'; detailsUrl = 'https://github.com/group/widget/actions/runs/1/job/11' });
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING -Checks $checks);

            $result = Invoke-Watch $f @('-UntilEvent', '-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('conflict', 'pipeline-failed');
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '1';
        }

        It 'keeps polling after an empty poll and exits after the poll with an event' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest);
            Set-Response $f 'pr' (New-PullRequest -Mergeable CONFLICTING) -Call 2;

            $result = Invoke-Watch $f @('-UntilEvent', '-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('conflict');
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '2';
        }

        It 'keeps polling after a failed poll and exits after the poll with an event' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING);
            Set-Response $f 'pr' '' -Call 1 -ExitCode 1 -Stderr 'error connecting to api.github.com';

            $result = Invoke-Watch $f @('-UntilEvent', '-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('conflict');
            $result.Stderr | Should -Match 'poll failed.*error connecting to api\.github\.com';
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '2';
        }

        It 'prints a terminal event and exits 0 as without the switch' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -State MERGED);

            $result = Invoke-Watch $f @('-UntilEvent', '-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('merged');
        }

        It 'throws on -Once with -UntilEvent before any poll' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING);

            $result = Invoke-Watch $f @('-Once', '-UntilEvent');

            $result.ExitCode | Should -Not -Be 0;
            $result.Stderr | Should -Match 'Pass -Once or -UntilEvent, not both\.';
            $result.Lines.Count | Should -Be 0;
            Test-Path (Join-Path $f.Responses 'pr.count') | Should -BeFalse;
        }

        It 'without the switch continues after a non-terminal event until merged' {
            $f = New-Fixture -Forge github;
            Set-GitHub $f (New-PullRequest -Mergeable CONFLICTING);
            Set-Response $f 'pr' (New-PullRequest -State MERGED) -Call 2;

            $result = Invoke-Watch $f @('-IntervalSeconds', '0.1');

            $result.ExitCode | Should -Be 0;
            Get-EventNames $result | Should -Be @('conflict', 'merged');
            Get-Content -LiteralPath (Join-Path $f.Responses 'pr.count') | Should -Be '2';
        }
    }

    Context 'pagination' {

        It 'reads inline review threads from every page' {
            $f = New-Fixture -Forge github;
            $page = {
                param($Id)
                @{ data = @{ repository = @{ pullRequest = @{ reviewThreads = @{ nodes = @(
                                        @{ isResolved = $false; path = 'a.ps1'; line = 1; comments = @{ nodes = @(@{ databaseId = $Id; body = "c$Id"; url = "u$Id"; author = @{ login = 'ann' } }) } }
                                    )
                                }
                            }
                        }
                    }
                }
            };
            Set-GitHub $f (New-PullRequest) (, @((& $page 1), (& $page 2)));

            $result = Invoke-Watch $f;

            @($result.Events[0].Comments).Id | Should -Be @('1', '2');
            Get-Content -LiteralPath (Join-Path $f.Responses 'calls.log') | Where-Object { $_ -like 'api graphql*' } | Should -BeLike 'api graphql --paginate --slurp *endCursor*';
        }

        It 'reads discussions from every page' {
            $f = New-Fixture -Forge gitlab;
            $discussions = foreach ($id in 1..3)
            {
                @{ id = "d$id"; notes = @(@{ id = $id; body = "n$id"; system = $false; author = @{ username = 'dee' } }) }
            }
            Set-GitLab $f (New-MergeRequest) -Discussions $discussions;

            @((Invoke-Watch $f).Events[0].Comments).Id | Should -Be @('1', '2', '3');
        }
    }
}
