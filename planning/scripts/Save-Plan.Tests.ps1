BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Save-Plan.ps1';

    # Stub tools. Each call appends "name|cwd|arg|arg..." to STUB_LOG; prettier exits
    # STUB_PRETTIER_RC and prints a line when that is non-zero.
    function New-Stub
    {
        param([string[]]$Name)

        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = @'
#!/bin/sh
line="${0##*/}|$PWD"
for a in "$@"; do line="$line|$a"; done
printf '%s\n' "$line" >> "$STUB_LOG"
if [ "${STUB_PRETTIER_RC:-0}" != 0 ]; then echo "prettier stub error" >&2; fi
exit "${STUB_PRETTIER_RC:-0}"
'@
        foreach ($item in $Name)
        {
            $stub = Join-Path $dir $item
            Set-Content $stub $body
            chmod +x $stub
        }

        $dir
    }

    # Runs Save-Plan with PATH set to $PathValue and the stub environment in place.
    function Invoke-SavePlan
    {
        param($Fixture, [string]$PathValue = $env:PATH, [hashtable]$Environment = @{}, [hashtable]$Extra = @{})

        $saved = @{ PATH = $env:PATH }
        $Environment['STUB_LOG'] = $script:StubLog
        foreach ($name in $Environment.Keys)
        {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }

        $env:PATH = $PathValue
        try
        {
            & $script:ScriptPath -PlansRepo $Fixture.PlansRepo -NoSync @Extra | ConvertFrom-Json
        }
        finally
        {
            foreach ($name in $saved.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }

    # Builds the fixture tree under $Base: a code repository, and with -Existing a plans
    # repository, and with -WithRemote a bare remote it tracks.
    function Build-FixtureTree
    {
        param([string]$Base, [switch]$Existing, [switch]$WithRemote)

        $codeRoot = Join-Path $Base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $plansRepo = Join-Path $codeRoot 'plans';

        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');
        git -C $repoRoot init --quiet --initial-branch=main;
        git -C $repoRoot add -A;
        git -C $repoRoot commit --quiet -m 'initial';

        $remote = Join-Path $Base 'remote.git';
        if ($Existing)
        {
            New-Item -ItemType Directory -Path (Join-Path $plansRepo 'widget') -Force | Out-Null;
            git -C $plansRepo init --quiet --initial-branch=main;
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
    }

    # Returns a fresh copy of the template built for these parameters, with the remote URL
    # rewritten to the copy. A parameter set without a template is built directly.
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

        $remote = Join-Path $base 'remote.git';
        $template = $script:Templates["$([bool]$Existing)|$([bool]$WithRemote)"];
        if ($template)
        {
            Copy-Item -LiteralPath $template -Destination $base -Recurse;
            if ($Existing -and $WithRemote)
            {
                git -C $plansRepo remote set-url origin "file://$remote";
            }
        }
        else
        {
            Build-FixtureTree -Base $base -Existing:$Existing -WithRemote:$WithRemote;
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

    # A PATH holding only git, so prettier is not found.
    function New-GitOnlyBin
    {
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));
        New-Item -ItemType Directory -Path $bin | Out-Null;
        $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source;
        New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'git') -Target $git | Out-Null;
        $bin
    }

    function Write-Plan($Fixture, [string]$Name = 'plan.md', [string]$Content = '# Plan: a plan')
    {
        New-Item -ItemType Directory -Path $Fixture.PlanDir -Force | Out-Null;
        $Content | Set-Content -LiteralPath (Join-Path $Fixture.PlanDir $Name);
    }

    # One git config for the whole file, so no repository needs its own identity or
    # commit.gpgsign setting and the developer's ~/.gitconfig is never read.
    $script:SavedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL;
    $gitConfig = Join-Path $TestDrive 'gitconfig';
    Set-Content -LiteralPath $gitConfig -Value "[user]`n`tname = Test User`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n";
    $env:GIT_CONFIG_GLOBAL = $gitConfig;

    # Templates, built once per parameter set and copied per test; never handed to a test.
    $script:Templates = @{};
    foreach ($set in @(@($false, $false), @($true, $false), @($true, $true)))
    {
        $dir = Join-Path $TestDrive "template-$([guid]::NewGuid().ToString('n').Substring(0, 8))";
        Build-FixtureTree -Base $dir -Existing:$set[0] -WithRemote:$set[1];
        $script:Templates["$($set[0])|$($set[1])"] = $dir;
    }
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal;
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

    Context 'formatting' {

        BeforeEach {
            $script:StubLog = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
            $script:ConfigPath = Join-Path $PSScriptRoot 'plan.prettierrc.json'
        }

        It 'runs prettier with the shipped config, only on the changed Markdown files' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            Write-Plan $f -Name 'notes.txt';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH);

            $result.Committed | Should -BeTrue;
            $calls = @(Get-Content -LiteralPath $script:StubLog);
            $calls | Should -HaveCount 1;
            $parts = $calls[0] -split '\|';
            $parts[1] | Should -Be (Resolve-Path -LiteralPath $f.PlansRepo).Path;
            $parts | Should -Contain '--no-editorconfig';
            $parts[($parts.IndexOf('--config') + 1)] | Should -Be $script:ConfigPath;
            $parts | Should -Contain 'widget/new.md';
            $parts | Should -Not -Contain 'widget/seed.md';
            $parts | Should -Not -Contain 'widget/notes.txt';
            $result.Format.Attempted | Should -BeTrue;
        }

        It 'passes exact paths for odd names and renames, and never a deleted file' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'keep.md';
            Write-Plan $f -Name 'gone.md';
            Write-Plan $f -Name 'old name.md' -Content 'rename me, with enough text that git sees a rename';
            git -C $f.PlansRepo add -A;
            git -C $f.PlansRepo commit --quiet -m 'more plans';
            Remove-Item -LiteralPath (Join-Path $f.PlanDir 'gone.md');
            Move-Item -LiteralPath (Join-Path $f.PlanDir 'old name.md') -Destination (Join-Path $f.PlanDir 'renamed ø.md');
            Write-Plan $f -Name 'my plan ø.md';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH);

            $result.Committed | Should -BeTrue;
            $parts = (@(Get-Content -LiteralPath $script:StubLog) | Select-Object -First 1) -split '\|';
            $parts | Should -Contain 'widget/my plan ø.md';
            $parts | Should -Contain 'widget/renamed ø.md';
            $parts | Should -Not -Contain 'widget/old name.md';
            $parts | Should -Not -Contain 'widget/gone.md';
            $parts | Should -Not -Contain 'widget/keep.md';
        }

        It 'does not call prettier with -NoFormat and reports disabled' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH) -Extra @{ NoFormat = $true };

            $result.Committed | Should -BeTrue;
            $result.Format.Skipped | Should -Be 'disabled';
            Test-Path -LiteralPath $script:StubLog | Should -BeFalse;
        }

        It 'reports no markdown changes and does not call prettier' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'notes.txt';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH);

            $result.Committed | Should -BeTrue;
            $result.Format.Skipped | Should -Be 'no markdown changes';
            Test-Path -LiteralPath $script:StubLog | Should -BeFalse;
        }

        It 'reports prettier not found and still commits' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));
            New-Item -ItemType Directory -Path $bin | Out-Null;
            # Only git is reachable: the stub directory holds nothing called prettier.
            $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source;
            New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'git') -Target $git | Out-Null;

            $result = Invoke-SavePlan $f -PathValue $bin;

            $result.Committed | Should -BeTrue;
            $result.Format.Skipped | Should -Be 'prettier not found';
            $result.Format.Attempted | Should -BeFalse;
        }

        It 'reports a prettier failure and still commits' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH) -Environment @{ STUB_PRETTIER_RC = '2' };

            $result.Committed | Should -BeTrue;
            $result.Format.Problem | Should -BeLike '*prettier stub error*';
            git -C $f.PlansRepo status --porcelain | Should -BeNullOrEmpty;
        }

        It 'does not call prettier with -WhatIf' {
            $f = New-Fixture -Existing;
            Write-Plan $f -Name 'new.md';
            $stub = New-Stub 'prettier';

            $result = Invoke-SavePlan $f -PathValue ($stub + [IO.Path]::PathSeparator + $env:PATH) -Extra @{ WhatIf = $true };

            Test-Path -LiteralPath $script:StubLog | Should -BeFalse;
            $result.Format.Skipped | Should -Be 'not attempted';
        }

        Context 'plan header conversion without prettier' {

            BeforeAll {
                $script:OldPlan = @(
                    '# Plan: a plan', '',
                    'Status: draft', 'Updated: 2026-11-18', '',
                    '## How to execute plan', '',
                    'Team: a, b', 'Verify: run it', 'continued here', '',
                    '```', 'Key: inside a fence', '```', '',
                    '## Goal', '', 'Note: this is prose.', ''
                ) -join "`n";
            }

            It 'commits an old-form plan with header and execute fields as list items' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;

                $result = Invoke-SavePlan $f -PathValue (New-GitOnlyBin);

                $result.Committed | Should -BeTrue;
                $result.Format.Skipped | Should -Be 'prettier not found';
                @($result.Format.Formatted) | Should -Contain 'widget/new.md';
                $lines = @(git -C $f.PlansRepo show 'HEAD:widget/new.md');
                foreach ($line in '- Status: draft', '- Updated: 2026-11-18', '- Team: a, b', '- Verify: run it', 'continued here', 'Key: inside a fence', 'Note: this is prose.')
                {
                    $lines | Should -Contain $line;
                }
            }

            It 'leaves a Key line inside a fenced code block and a body paragraph alone' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;

                Invoke-SavePlan $f -PathValue (New-GitOnlyBin) | Out-Null;

                $text = git -C $f.PlansRepo show 'HEAD:widget/new.md' | Out-String;
                $text | Should -Not -Match '- Key: inside';
                $text | Should -Not -Match '- Note: ';
            }

            It 'commits a Markdown file that is not a plan unchanged' {
                $f = New-Fixture -Existing;
                $content = "# Notes`n`nStatus: draft`nUpdated: today`n";
                Write-Plan $f -Name 'notes.md' -Content $content;

                $result = Invoke-SavePlan $f -PathValue (New-GitOnlyBin);

                (git -C $f.PlansRepo show 'HEAD:widget/notes.md' | Out-String).TrimEnd() | Should -Be $content.TrimEnd();
                @($result.Format.Formatted) | Should -HaveCount 0;
            }

            It 'converts a second time without changing anything' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;
                Invoke-SavePlan $f -PathValue (New-GitOnlyBin) | Out-Null;
                $path = Join-Path $f.PlanDir 'new.md';
                $once = Get-Content -Raw -LiteralPath $path;
                # new.md must be staged again, or conversion never sees the converted text.
                'a later body line' | Add-Content -LiteralPath $path;

                $result = Invoke-SavePlan $f -PathValue (New-GitOnlyBin);

                $result.Committed | Should -BeTrue;
                @($result.Format.Formatted) | Should -HaveCount 0;
                $text = Get-Content -Raw -LiteralPath $path;
                $text | Should -Be ($once + "a later body line`n");
                @($text -split "`r?`n" | Where-Object { $_ -match '^- - ' }) | Should -HaveCount 0;
                $text | Should -BeLike '*- Status: draft*- Updated: 2026-11-18*- Team: a, b*- Verify: run it*';
            }

            It 'reports a file it cannot write, leaves it as it was and still commits' -Skip:($IsWindows -or ((id -u) -eq '0')) {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;
                $path = Join-Path $f.PlanDir 'new.md';
                $before = Get-Content -Raw -LiteralPath $path;
                chmod 444 $path;
                try
                {
                    $result = Invoke-SavePlan $f -PathValue (New-GitOnlyBin);
                }
                finally
                {
                    chmod 644 $path;
                }

                $result.Committed | Should -BeTrue;
                $result.Format.Problem | Should -BeLike "*plan header conversion failed for 'widget/new.md'*";
                @($result.Format.Formatted) | Should -HaveCount 0;
                Get-Content -Raw -LiteralPath $path | Should -Be $before;
                (git -C $f.PlansRepo show 'HEAD:widget/new.md' | Out-String) | Should -Not -Match '- Status:';
            }

            It 'keeps CRLF line endings' {
                $f = New-Fixture -Existing;
                New-Item -ItemType Directory -Path $f.PlanDir -Force | Out-Null;
                [IO.File]::WriteAllText((Join-Path $f.PlanDir 'new.md'), ($script:OldPlan -replace "`n", "`r`n"));

                Invoke-SavePlan $f -PathValue (New-GitOnlyBin) | Out-Null;

                $text = [IO.File]::ReadAllText((Join-Path $f.PlanDir 'new.md'));
                $text | Should -BeLike "*- Status: draft`r`n*";
                $text | Should -Not -Match "(?<!`r)`n";
            }

            It 'converts nothing with -NoFormat' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;

                Invoke-SavePlan $f -PathValue (New-GitOnlyBin) -Extra @{ NoFormat = $true } | Out-Null;

                $text = git -C $f.PlansRepo show 'HEAD:widget/new.md' | Out-String;
                $text | Should -Not -Match '- Status:';
            }

            It 'converts nothing with -WhatIf' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:OldPlan;

                Invoke-SavePlan $f -PathValue (New-GitOnlyBin) -Extra @{ WhatIf = $true } | Out-Null;

                Get-Content -Raw -LiteralPath (Join-Path $f.PlanDir 'new.md') | Should -Not -Match '- Status:';
            }
        }

        Context 'with the real prettier' {

            BeforeAll {
                if (-not (Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue))
                {
                    throw 'prettier is required for these tests but was not found on PATH. Install it (npm install -g prettier).'
                }
            }

            It 'commits a ragged plan formatted and lists it as formatted' {
                $f = New-Fixture -Existing;
                $content = "# Plan`n`n* one`n* two`n`n| a | b |`n|--|--|`n| longer cell | x |`n";
                Write-Plan $f -Name 'new.md' -Content $content;

                $result = Invoke-SavePlan $f;

                $result.Committed | Should -BeTrue;
                @($result.Format.Formatted) | Should -Contain 'widget/new.md';
                $committed = git -C $f.PlansRepo show 'HEAD:widget/new.md' | Out-String;
                $committed | Should -Match '- one';
                $committed | Should -Match '\| a +\| b +\|';
                git -C $f.PlansRepo status --porcelain | Should -BeNullOrEmpty;
            }

            It 'leaves an already formatted plan alone' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content "# Plan`n`n- one";

                $result = Invoke-SavePlan $f;

                $result.Format.Attempted | Should -BeTrue;
                @($result.Format.Formatted) | Should -HaveCount 0;
            }

            BeforeAll {
                $d = [string]::new([char]0x222B, 2);
                $script:Marker = "<!-- user input $d`nfirst line`n`n  second   line`n$d -->";
                $script:Long = (1..40 | ForEach-Object { 'word' }) -join ' ';
                $script:Short = (1..12 | ForEach-Object { 'word' }) -join ' ';
                $script:RealPlan = @(
                    '# Plan: a plan', '',
                    'Status: draft', 'Updated: 2026-11-18', 'Repo: widget', 'Branch: main', 'Base: main', '',
                    '## How to execute plan', '',
                    'Team: a, b, c',
                    'Verify: run the full Pester suite for the planning scripts and then',
                    'read every failure message to the end before reporting',
                    'Review: one reviewer',
                    'Commit: one per step', '',
                    '## Steps', '',
                    '1. First step', '2. Second step', '',
                    '## Goal', '', $script:Long, '', $script:Short, '',
                    '| a | b |', '|--|--|', '| longer cell | x |', '', $script:Marker, ''
                ) -join "`n";
            }

            It 'converts and wraps an old-form plan, keeping steps, table and marker' {
                $f = New-Fixture -Existing;
                # Ambient config that would wrap prose and compact tables if it won over the
                # shipped config.
                '{"proseWrap":"always","printWidth":20}' | Set-Content -LiteralPath (Join-Path $f.PlansRepo '.prettierrc.json');
                "root = true`n[*]`nmax_line_length = 20`n" | Set-Content -LiteralPath (Join-Path $f.PlansRepo '.editorconfig');
                Write-Plan $f -Name 'new.md' -Content $script:RealPlan;

                $result = Invoke-SavePlan $f;

                $result.Committed | Should -BeTrue;
                $text = git -C $f.PlansRepo show 'HEAD:widget/new.md' | Out-String;
                $lines = @($text -split "`r?`n");
                foreach ($line in '- Status: draft', '- Updated: 2026-11-18', '- Repo: widget', '- Branch: main', '- Base: main',
                    '- Team: a, b, c', '- Review: one reviewer', '- Commit: one per step',
                    '1. First step', '2. Second step', '| a           | b   |', $script:Short)
                {
                    $lines | Should -Contain $line;
                }
                $v = [array]::FindIndex($lines, [Predicate[string]] { $args[0] -like '- Verify: *' });
                $v | Should -BeGreaterThan -1;
                $lines[$v + 1] | Should -Match '^  \S';
                @($lines | Where-Object { $_.Length -gt 80 -and $_ -notmatch '^\|' }) | Should -HaveCount 0;
                $text.Contains($script:Marker) | Should -BeTrue;
            }

            It 'reports only a one-word edit when the committed plan is saved again' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'new.md' -Content $script:RealPlan;
                Invoke-SavePlan $f | Out-Null;
                $path = Join-Path $f.PlanDir 'new.md';
                (Get-Content -Raw -LiteralPath $path).Replace('Second step', 'Middle step') | Set-Content -LiteralPath $path -NoNewline;

                $result = Invoke-SavePlan $f;

                $result.Committed | Should -BeTrue;
                @($result.Format.Formatted) | Should -HaveCount 0;
                (git -C $f.PlansRepo diff --numstat HEAD~1 HEAD) | Should -Match '^1\s+1\s+widget/new.md$';
            }

            It 'reports nothing formatted for a plan already in list form and wrapped' {
                $f = New-Fixture -Existing;
                Write-Plan $f -Name 'first.md' -Content $script:RealPlan;
                Invoke-SavePlan $f | Out-Null;
                $formatted = Get-Content -Raw -LiteralPath (Join-Path $f.PlanDir 'first.md');
                New-Item -ItemType Directory -Path $f.PlanDir -Force | Out-Null;
                [IO.File]::WriteAllText((Join-Path $f.PlanDir 'second.md'), $formatted);

                $result = Invoke-SavePlan $f;

                $result.Format.Attempted | Should -BeTrue;
                @($result.Format.Formatted) | Should -HaveCount 0;
            }
        }
    }
}
