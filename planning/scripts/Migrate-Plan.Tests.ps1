BeforeDiscovery {
    # Linux cannot set a file's birth time: the CreationTime setter leaves it alone, so a
    # plan there can never look older than its last write. Probe once, by read-back.
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'));
    try
    {
        '' | Set-Content -LiteralPath $probe;
        (Get-Item -LiteralPath $probe).CreationTime = [datetime]'2001-02-03 04:05';
        $script:CanSetCreationTime = (Get-Item -LiteralPath $probe).CreationTime.Date -eq [datetime]'2001-02-03';
    }
    finally
    {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue;
    }
}

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Migrate-Plan.ps1';

    function New-Fixture
    {
        param(
            [string]$Status = 'DONE',
            [string]$Heading = '# Plan: rework the parser',
            [switch]$NoStatus,
            [switch]$NoUpdated,
            [switch]$ListForm,
            [switch]$NoPlan,
            [switch]$NoGit,
            [string]$Extra = ''
        )

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $plansRepo = Join-Path $codeRoot 'plans';

        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;

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

        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'f.txt');
        if (-not $NoGit)
        {
            git -C $repoRoot init --quiet --initial-branch=main;
            git -C $repoRoot config commit.gpgsign false;
            git -C $repoRoot remote add origin 'https://example.com/group/widget.git';
            git -C $repoRoot add -A;
            git -C $repoRoot commit --quiet -m 'init';
        }

        $planPath = Join-Path $repoRoot 'PLAN.md';
        if (-not $NoPlan)
        {
            $lines = @($Heading, '');
            $m = if ($ListForm) { '- ' } else { '' };
            if (-not $NoStatus) { $lines += "${m}Status: $Status" }
            if (-not $NoUpdated) { $lines += "${m}Updated: 2026-07-04" }
            $lines += @('', '## Goal', '', 'Make it work.', '');
            if ($Extra) { $lines += $Extra }
            ($lines -join "`n") | Set-Content -LiteralPath $planPath -NoNewline;
            $f = Get-Item -LiteralPath $planPath;
            $f.CreationTime = [datetime]'2026-07-04 09:00';
            $f.LastWriteTime = [datetime]'2026-07-06 17:00';
        }

        # The date the plan is filed under: its creation time where the platform kept it,
        # otherwise the last write time the script falls back to.
        # The tests that use it pass either way, so they rely on 'dates the file from when the
        # plan was written' running wherever the probe says CreationTime can be set: do not
        # skip or loosen that test any further.
        $date = if ($NoPlan -or (Get-Item -LiteralPath $planPath).CreationTime.Date -eq [datetime]'2026-07-04') { '2026-07-04' } else { '2026-07-06' };

        return [pscustomobject]@{
            Date      = $date
            Base      = $base
            RepoRoot  = $repoRoot
            PlansRepo = $plansRepo
            PlanDir   = Join-Path $plansRepo 'widget'
            PlanPath  = $planPath
        }
    }

    function Initialize-BreakingPlansRepo($Fixture)
    {
        # A plans repository whose commits fail, without a hook: an executable bit is not
        # portable and gpg.program is honoured on every platform.
        New-Item -ItemType Directory -Path $Fixture.PlansRepo -Force | Out-Null;
        git -C $Fixture.PlansRepo init --quiet --initial-branch=main;
        git -C $Fixture.PlansRepo config commit.gpgsign true;
        git -C $Fixture.PlansRepo config gpg.program (Join-Path $Fixture.Base 'no-such-gpg');
    }

    function Repair-PlansRepo($Fixture)
    {
        git -C $Fixture.PlansRepo config commit.gpgsign false;
    }

    function Invoke-Migrate($Fixture, [hashtable]$Extra = @{})
    {
        # A hashtable splat, not an array: array splatting binds positionally, so a switch
        # like -KeepSource would land in the first positional parameter instead.
        $params = @{ RepoPath = $Fixture.RepoRoot } + $Extra;
        return (& $script:ScriptPath @params | ConvertFrom-Json);
    }
}

Describe 'Migrate-Plan' {

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

    Context 'placing the plan' {

        It 'moves PLAN.md into the plans repository under the repo name' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;

            Split-Path $result.Destination -Parent | Should -Be $f.PlanDir;
            Test-Path -LiteralPath $result.Destination | Should -BeTrue;
        }

        # Skipped where the platform cannot set a file's birth time (Linux): a plan there
        # can never be older than its last write, so creation-time precedence cannot be arranged.
        It 'dates the file from when the plan was written, not from today' -Skip:(-not $CanSetCreationTime) {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;

            Split-Path $result.Destination -Leaf | Should -Be '2026-07-04-rework-the-parser.md';
        }

        It 'falls back to the last write time when creation time is unusable' {
            $f = New-Fixture;
            $file = Get-Item -LiteralPath $f.PlanPath;
            $file.CreationTime = [datetime]'2026-08-01 12:00';
            # Where birth time cannot be set, the setter moves the last write time instead.
            $file.LastWriteTime = [datetime]'2026-07-06 17:00';
            $result = Invoke-Migrate $f;

            Split-Path $result.Destination -Leaf | Should -Be '2026-07-06-rework-the-parser.md';
        }

        It 'takes the title from a plain heading when there is no Plan: prefix' {
            $f = New-Fixture -Heading '# Cache invalidation';
            $result = Invoke-Migrate $f;

            $result.Title | Should -Be 'Cache invalidation';
            Split-Path $result.Destination -Leaf | Should -Be "$($f.Date)-cache-invalidation.md";
        }

        It 'suffixes rather than overwriting when the dated slug is taken' {
            $f = New-Fixture;
            New-Item -ItemType Directory -Path $f.PlanDir -Force | Out-Null;
            'existing' | Set-Content -LiteralPath (Join-Path $f.PlanDir "$($f.Date)-rework-the-parser.md");

            $result = Invoke-Migrate $f;

            Split-Path $result.Destination -Leaf | Should -Be "$($f.Date)-rework-the-parser-2.md";
            Get-Content -Raw -LiteralPath (Join-Path $f.PlanDir "$($f.Date)-rework-the-parser.md") |
                Should -BeLike 'existing*';
        }
    }

    Context 'the header block' {

        It 'adds a Repo line pointing at the repository the plan is about' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;

            Get-Content -Raw -LiteralPath $result.Destination | Should -BeLike "*Repo: $($f.RepoRoot)*";
        }

        It 'puts Repo directly after Updated' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;
            $lines = @(Get-Content -LiteralPath $result.Destination);
            $i = [array]::FindIndex($lines, [Predicate[string]] { $args[0] -like '- Updated:*' });

            # The bare header is converted to list form by the save that commits the plan.
            $i | Should -BeGreaterThan -1;
            $lines[$i + 1] | Should -Be "- Repo: $($f.RepoRoot)";
        }

        It 'inserts Repo as a list item after Updated in a list-form plan' {
            $f = New-Fixture -ListForm;
            $result = Invoke-Migrate $f;
            $lines = @(Get-Content -LiteralPath $result.Destination);
            $i = [array]::IndexOf($lines, '- Updated: 2026-07-04');

            $result.Status | Should -Be 'DONE';
            $i | Should -BeGreaterThan -1;
            $lines[$i + 1] | Should -Be "- Repo: $($f.RepoRoot)";
        }

        It 'inserts Repo as a list item after Status when a list-form plan has no Updated' {
            $f = New-Fixture -ListForm -NoUpdated;
            $result = Invoke-Migrate $f;
            $lines = @(Get-Content -LiteralPath $result.Destination);
            $i = [array]::IndexOf($lines, '- Status: DONE');

            $i | Should -BeGreaterThan -1;
            $lines[$i + 1] | Should -Be "- Repo: $($f.RepoRoot)";
        }

        It 'leaves an existing list-form Repo line alone' {
            $f = New-Fixture -ListForm -Extra '- Repo: /somewhere/else';
            $result = Invoke-Migrate $f;
            $text = Get-Content -Raw -LiteralPath $result.Destination;

            ([regex]::Matches($text, '(?m)^(- )?Repo:')).Count | Should -Be 1;
        }

        It 'carries Status, Branch and Base across unchanged' {
            $f = New-Fixture -Status 'IMPLEMENTING' -Extra "Branch: kbi/parser`nBase: abc1234";
            $result = Invoke-Migrate $f;
            $text = Get-Content -Raw -LiteralPath $result.Destination;

            $result.Status | Should -Be 'IMPLEMENTING';
            $text | Should -BeLike '*Status: IMPLEMENTING*';
            $text | Should -BeLike '*Branch: kbi/parser*';
            $text | Should -BeLike '*Base: abc1234*';
        }

        It 'leaves an existing Repo line alone' {
            $f = New-Fixture -Extra 'Repo: /somewhere/else';
            $result = Invoke-Migrate $f;
            $text = Get-Content -Raw -LiteralPath $result.Destination;

            $text | Should -BeLike '*Repo: /somewhere/else*';
            ([regex]::Matches($text, '(?m)^Repo:')).Count | Should -Be 1;
        }

        It 'copies the body verbatim, markers included' {
            $f = New-Fixture -Extra '∫∫split this step in two∫∫';
            $result = Invoke-Migrate $f;

            Get-Content -Raw -LiteralPath $result.Destination | Should -BeLike '*∫∫split this step in two∫∫*';
            $result.Markers | Should -Be 1;
        }
    }

    Context 'committing and removing the source' {

        It 'commits the migrated plan with a message naming it' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;

            $result.Committed | Should -BeTrue;
            git -C $f.PlansRepo log -1 --pretty=%s | Should -Be 'migrate plan: rework the parser';
            git -C $f.PlansRepo status --porcelain | Should -BeNullOrEmpty;
        }

        It 'removes the original once it is committed' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f;

            Test-Path -LiteralPath $f.PlanPath | Should -BeFalse;
            $result.SourceKept | Should -BeFalse;
        }

        It 'keeps the original with -KeepSource' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f @{ KeepSource = $true };

            Test-Path -LiteralPath $f.PlanPath | Should -BeTrue;
            $result.SourceKept | Should -BeTrue;
            $result.Committed | Should -BeTrue;
        }

        It 'leaves no destination behind when the commit fails' {
            $f = New-Fixture;
            Initialize-BreakingPlansRepo $f;
            $expected = Join-Path $f.PlanDir "$($f.Date)-rework-the-parser.md";

            { Invoke-Migrate $f } | Should -Throw;

            Test-Path -LiteralPath $expected | Should -BeFalse;
            Test-Path -LiteralPath $f.PlanPath | Should -BeTrue;
            git -C $f.PlansRepo diff --cached --name-only | Should -BeNullOrEmpty;
        }

        It 'retries onto the same name after a failed commit rather than a numbered duplicate' {
            $f = New-Fixture;
            Initialize-BreakingPlansRepo $f;
            { Invoke-Migrate $f } | Should -Throw;

            Repair-PlansRepo $f;
            $result = Invoke-Migrate $f;

            Split-Path $result.Destination -Leaf | Should -Be "$($f.Date)-rework-the-parser.md";
            $result.Committed | Should -BeTrue;
            @(Get-ChildItem -LiteralPath $f.PlanDir -Filter '*.md').Count | Should -Be 1;
            Test-Path -LiteralPath $f.PlanPath | Should -BeFalse;
        }

        It 'never touches the repository the plan came from' {
            $f = New-Fixture;
            $before = git -C $f.RepoRoot rev-parse HEAD;
            Invoke-Migrate $f | Out-Null;

            git -C $f.RepoRoot rev-parse HEAD | Should -Be $before;
            git -C $f.RepoRoot status --porcelain | Should -BeNullOrEmpty;
        }
    }

    Context 'guards' {

        It 'throws when there is no plan to migrate' {
            $f = New-Fixture -NoPlan;
            { Invoke-Migrate $f } | Should -Throw -ExpectedMessage '*Nothing to migrate*';
        }

        It 'throws on a file with no Status line rather than guessing' {
            $f = New-Fixture -NoStatus;
            { Invoke-Migrate $f } | Should -Throw -ExpectedMessage '*no ''Status:'' line*';
        }

        It 'throws outside a git work tree' {
            $f = New-Fixture -NoGit;
            { Invoke-Migrate $f } | Should -Throw -ExpectedMessage '*not inside a git work tree*';
        }

        It 'migrates a plan named explicitly somewhere other than the repo root' {
            $f = New-Fixture;
            $moved = Join-Path $f.RepoRoot 'docs';
            New-Item -ItemType Directory -Path $moved -Force | Out-Null;
            Move-Item -LiteralPath $f.PlanPath -Destination (Join-Path $moved 'PLAN.md');

            $result = Invoke-Migrate $f @{ PlanPath = (Join-Path $moved 'PLAN.md') };

            $result.Committed | Should -BeTrue;
            Test-Path -LiteralPath (Join-Path $moved 'PLAN.md') | Should -BeFalse;
        }
    }

    Context 'dry run' {

        It 'touches nothing with -WhatIf' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f @{ WhatIf = $true };

            Test-Path -LiteralPath $f.PlanPath | Should -BeTrue;
            Test-Path -LiteralPath $result.Destination | Should -BeFalse;
            Test-Path -LiteralPath $f.PlansRepo | Should -BeFalse;
            $result.Committed | Should -BeFalse;
        }

        It 'still reports where the plan would land' {
            $f = New-Fixture;
            $result = Invoke-Migrate $f @{ WhatIf = $true };

            Split-Path $result.Destination -Leaf | Should -Be "$($f.Date)-rework-the-parser.md";
            $result.Title | Should -Be 'rework the parser';
        }
    }
}
