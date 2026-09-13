BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Save-Plan.ps1';

    function New-Fixture
    {
        param([switch]$Existing, [switch]$WithRemote)

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $plansRepo = Join-Path $codeRoot 'plans';

        # Identity comes from the environment so the tests never depend on, or touch, the
        # machine's git config.
        $script:SavedEnv = @{
            XDG_CONFIG_HOME     = $env:XDG_CONFIG_HOME
            CLAUDE_PLANS_REPO   = $env:CLAUDE_PLANS_REPO
            __CODE_ROOT         = $env:__CODE_ROOT
            GIT_AUTHOR_NAME     = $env:GIT_AUTHOR_NAME
            GIT_AUTHOR_EMAIL    = $env:GIT_AUTHOR_EMAIL
            GIT_COMMITTER_NAME  = $env:GIT_COMMITTER_NAME
            GIT_COMMITTER_EMAIL = $env:GIT_COMMITTER_EMAIL
        };
        $env:XDG_CONFIG_HOME = Join-Path $base 'config';
        $env:CLAUDE_PLANS_REPO = $null;
        $env:__CODE_ROOT = $codeRoot;
        $env:GIT_AUTHOR_NAME = 'Test User';
        $env:GIT_AUTHOR_EMAIL = 'test@example.com';
        $env:GIT_COMMITTER_NAME = 'Test User';
        $env:GIT_COMMITTER_EMAIL = 'test@example.com';

        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');
        git -C $repoRoot init --quiet --initial-branch=main;
        git -C $repoRoot config commit.gpgsign false;
        git -C $repoRoot add -A;
        git -C $repoRoot commit --quiet -m 'initial';

        $remote = Join-Path $base 'remote.git';
        if ($Existing)
        {
            New-Item -ItemType Directory -Path (Join-Path $plansRepo 'widget') -Force | Out-Null;
            git -C $plansRepo init --quiet --initial-branch=main;
            git -C $plansRepo config commit.gpgsign false;
            'seed' | Set-Content -LiteralPath (Join-Path $plansRepo 'widget/seed.md');
            git -C $plansRepo add -A;
            git -C $plansRepo commit --quiet -m 'seed';

            if ($WithRemote)
            {
                # A local bare repository: a real upstream, no network.
                git init --quiet --bare --initial-branch=main $remote;
                git -C $plansRepo remote add origin "file://$remote";
                git -C $plansRepo push --quiet -u origin main;
            }
        }

        return [pscustomobject]@{
            Base      = $base
            RepoRoot  = $repoRoot
            PlansRepo = $plansRepo
            PlanDir   = Join-Path $plansRepo 'widget'
            Remote    = $remote
            LockPath  = Join-Path $plansRepo '.claude-plan.lock'
            StampPath = Join-Path $plansRepo '.git/claude-plan-last-sync'
        }
    }

    function Write-Plan($Fixture, [string]$Name = 'plan.md', [string]$Content = '# Plan: a plan')
    {
        New-Item -ItemType Directory -Path $Fixture.PlanDir -Force | Out-Null;
        $Content | Set-Content -LiteralPath (Join-Path $Fixture.PlanDir $Name);
    }
}

Describe 'Save-Plan' {

    AfterEach {
        if ($script:SavedEnv)
        {
            foreach ($name in $script:SavedEnv.Keys)
            {
                Set-Item -Path "env:$name" -Value $script:SavedEnv[$name] -ErrorAction SilentlyContinue;
            }
            $script:SavedEnv = $null;
        }
    }

    Context 'first run' {

        It 'creates and initialises the plans repository, then commits' {
            $f = New-Fixture;
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Initialised | Should -BeTrue;
            Test-Path -LiteralPath (Join-Path $f.PlansRepo '.git') | Should -BeTrue;
            $result.Committed | Should -BeFalse;
        }

        It 'commits the first plan written into a fresh repository' {
            $f = New-Fixture;
            Write-Plan $f;
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Initialised | Should -BeTrue;
            $result.Committed | Should -BeTrue;
            @($result.ChangedFiles) | Should -Contain 'widget/plan.md';
            git -C $f.PlansRepo log -1 --pretty=%s | Should -Be 'update plans';
        }
    }

    Context 'committing' {

        It 'commits every change under a standard message' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            Set-Content -LiteralPath (Join-Path $f.PlanDir 'seed.md') -Value 'edited';

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            @($result.ChangedFiles) | Should -Contain 'widget/new.md';
            @($result.ChangedFiles) | Should -Contain 'widget/seed.md';
            git -C $f.PlansRepo status --porcelain | Should -BeNullOrEmpty;
        }

        It 'takes a custom message' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';

            & $script:ScriptPath -PlansRepo $f.PlansRepo -Message 'plan: move plans out of the working tree' | Out-Null;

            git -C $f.PlansRepo log -1 --pretty=%s | Should -Be 'plan: move plans out of the working tree';
        }

        It 'commits a deletion as readily as an edit' {
            $f = New-Fixture -Existing;
            Remove-Item -LiteralPath (Join-Path $f.PlanDir 'seed.md');

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            @($result.ChangedFiles) | Should -Contain 'widget/seed.md';
        }

        It 'reports nothing to commit without failing, so it is safe to call after every write' {
            $f = New-Fixture -Existing;
            $before = git -C $f.PlansRepo rev-parse HEAD;

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Committed | Should -BeFalse;
            $result.Commit | Should -BeNullOrEmpty;
            $result.ChangedFiles | Should -BeNullOrEmpty;
            git -C $f.PlansRepo rev-parse HEAD | Should -Be $before;
        }

        It 'returns the commit it made' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Commit | Should -Be (git -C $f.PlansRepo rev-parse HEAD);
        }
    }

    Context 'resolving the plans repository' {

        It 'falls back to Get-PlanContext when -PlansRepo is not given' {
            $f = New-Fixture;
            Write-Plan $f;

            Push-Location $f.RepoRoot;
            try
            {
                $result = & $script:ScriptPath | ConvertFrom-Json;
            }
            finally
            {
                Pop-Location;
            }

            $result.PlansRepo | Should -Be (Resolve-Path -LiteralPath $f.PlansRepo).Path;
            $result.Committed | Should -BeTrue;
        }
    }

    Context 'dry run' {

        It 'touches nothing with -WhatIf' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $before = git -C $f.PlansRepo rev-parse HEAD;

            & $script:ScriptPath -PlansRepo $f.PlansRepo -WhatIf | Out-Null;

            git -C $f.PlansRepo rev-parse HEAD | Should -Be $before;
            git -C $f.PlansRepo status --porcelain | Should -Contain '?? widget/new.md';
        }

        It 'creates no repository with -WhatIf' {
            $f = New-Fixture;

            & $script:ScriptPath -PlansRepo $f.PlansRepo -WhatIf | Out-Null;

            Test-Path -LiteralPath $f.PlansRepo | Should -BeFalse;
        }
    }

    Context 'the lock' {

        It 'releases the lock when it is done' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync | Out-Null;

            Test-Path -LiteralPath $f.LockPath | Should -BeFalse;
        }

        It 'releases the lock even when the commit fails' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            # An unparseable committer makes git commit fail without leaving the repo broken.
            $env:GIT_COMMITTER_EMAIL = '';
            $env:GIT_COMMITTER_NAME = '';
            $env:EMAIL = '';

            { & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync } | Should -Throw;

            Test-Path -LiteralPath $f.LockPath | Should -BeFalse;
        }

        It 'refuses to run while another session holds the lock' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            New-Item -ItemType Directory -Path $f.LockPath | Out-Null;

            { & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync -LockTimeoutSeconds 1 } |
                Should -Throw -ExpectedMessage '*Timed out*waiting for the plans repository lock*';

            git -C $f.PlansRepo status --porcelain | Should -Not -BeNullOrEmpty;
        }

        It 'breaks a lock old enough to belong to a dead session' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            New-Item -ItemType Directory -Path $f.LockPath | Out-Null;
            $item = Get-Item -LiteralPath $f.LockPath -Force;
            $item.CreationTime = (Get-Date).AddHours(-1);
            $item.LastWriteTime = (Get-Date).AddHours(-1);

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync -LockTimeoutSeconds 1 | ConvertFrom-Json;

            $result.BrokeLock | Should -BeTrue;
            $result.Committed | Should -BeTrue;
            Test-Path -LiteralPath $f.LockPath | Should -BeFalse;
        }

        It 'never commits the lock, because an empty directory is invisible to git' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync | ConvertFrom-Json;

            @($result.ChangedFiles) | Should -Not -Contain '.claude-plan.lock';
            git -C $f.PlansRepo log -1 --pretty=format: --name-only |
                Where-Object { $_ -like '*claude-plan.lock*' } | Should -BeNullOrEmpty;
            git -C $f.PlansRepo status --porcelain | Should -BeNullOrEmpty;
        }
    }

    Context 'pulling and pushing' {

        It 'skips the remote entirely when there is no upstream' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            $result.Sync.Attempted | Should -BeFalse;
            $result.Sync.Skipped | Should -Be 'no upstream';
            $result.Sync.Problem | Should -BeNullOrEmpty;
        }

        It 'pulls and pushes on the first write, and the remote receives the commit' {
            $f = New-Fixture -Existing -WithRemote;
            Write-Plan $f -Name 'new.md';
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $result.Sync.Attempted | Should -BeTrue;
            $result.Sync.Pulled | Should -BeTrue;
            $result.Sync.Pushed | Should -BeTrue;
            $result.Sync.Problem | Should -BeNullOrEmpty;
            git -C $f.Remote log -1 --pretty=%s | Should -Be 'update plans';
        }

        It 'does not sync again inside the interval' {
            $f = New-Fixture -Existing -WithRemote;
            Write-Plan $f -Name 'one.md';
            & $script:ScriptPath -PlansRepo $f.PlansRepo | Out-Null;

            Write-Plan $f -Name 'two.md';
            $second = & $script:ScriptPath -PlansRepo $f.PlansRepo | ConvertFrom-Json;

            $second.Committed | Should -BeTrue;
            $second.Sync.Attempted | Should -BeFalse;
            $second.Sync.Skipped | Should -BeLike 'last synced * ago';
        }

        It 'syncs again once the interval has passed' {
            $f = New-Fixture -Existing -WithRemote;
            Write-Plan $f -Name 'one.md';
            & $script:ScriptPath -PlansRepo $f.PlansRepo | Out-Null;

            Write-Plan $f -Name 'two.md';
            $second = & $script:ScriptPath -PlansRepo $f.PlansRepo -SyncIntervalSeconds 0 | ConvertFrom-Json;

            $second.Sync.Attempted | Should -BeTrue;
            $second.Sync.Pushed | Should -BeTrue;
            git -C $f.Remote log -1 --pretty=format: --name-only |
                Where-Object { $_ -like '*two.md' } | Should -Not -BeNullOrEmpty;
        }

        It 'forces a sync with -SyncNow' {
            $f = New-Fixture -Existing -WithRemote;
            Write-Plan $f -Name 'one.md';
            & $script:ScriptPath -PlansRepo $f.PlansRepo | Out-Null;

            Write-Plan $f -Name 'two.md';
            $second = & $script:ScriptPath -PlansRepo $f.PlansRepo -SyncNow | ConvertFrom-Json;

            $second.Sync.Attempted | Should -BeTrue;
            $second.Sync.Pushed | Should -BeTrue;
        }

        It 'skips the remote with -NoSync' {
            $f = New-Fixture -Existing -WithRemote;
            Write-Plan $f -Name 'new.md';
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo -NoSync | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            $result.Sync.Attempted | Should -BeFalse;
            $result.Sync.Skipped | Should -Be 'disabled';
            git -C $f.Remote log --oneline | Should -HaveCount 1;
        }

        It 'reports an unreachable remote instead of failing the write' {
            $f = New-Fixture -Existing -WithRemote;
            Remove-Item -LiteralPath $f.Remote -Recurse -Force;
            Write-Plan $f -Name 'new.md';

            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo -SyncNow | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            $result.Sync.Attempted | Should -BeTrue;
            $result.Sync.Pushed | Should -BeFalse;
            $result.Sync.Problem | Should -Not -BeNullOrEmpty;
        }

        It 'leaves the repository clean when a pull cannot be rebased' {
            $f = New-Fixture -Existing -WithRemote;

            # Another machine edits the same plan and pushes first.
            $other = Join-Path $f.Base 'other';
            git clone --quiet "file://$($f.Remote)" $other;
            git -C $other config commit.gpgsign false;
            Set-Content -LiteralPath (Join-Path $other 'widget/seed.md') -Value 'theirs';
            git -C $other add -A;
            git -C $other commit --quiet -m 'theirs';
            git -C $other push --quiet;

            Set-Content -LiteralPath (Join-Path $f.PlanDir 'seed.md') -Value 'ours';
            $result = & $script:ScriptPath -PlansRepo $f.PlansRepo -SyncNow | ConvertFrom-Json;

            $result.Committed | Should -BeTrue;
            $result.Sync.Problem | Should -BeLike '*git pull --rebase failed*';
            git -C $f.PlansRepo rev-parse --verify -q REBASE_HEAD 2>$null | Should -BeNullOrEmpty;
            Test-Path -LiteralPath (Join-Path $f.PlansRepo '.git/rebase-merge') | Should -BeFalse;
            Test-Path -LiteralPath $f.LockPath | Should -BeFalse;
        }
    }
}
