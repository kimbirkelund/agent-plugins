BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-PlanContext.ps1';

    function New-Fixture
    {
        param(
            [string]$OriginUrl = 'git@gitlab-test:group/widget.git',
            [switch]$NoOrigin,
            [switch]$NoGit,
            [string]$Branch = 'main'
        )

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        # The default resolution puts the plans repository under the code root, so the
        # fixture agrees with it rather than asserting against a path nothing produces.
        $plansRepo = Join-Path $codeRoot 'plans';
        $configHome = Join-Path $base 'config';

        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;
        New-Item -ItemType Directory -Path $configHome -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');

        if (-not $NoGit)
        {
            git -C $repoRoot init --quiet --initial-branch=$Branch;
            git -C $repoRoot config user.name 'Test User';
            git -C $repoRoot config user.email 'test@example.com';
            git -C $repoRoot config commit.gpgsign false;
            git -C $repoRoot add -A;
            git -C $repoRoot commit --quiet -m 'initial';
            if (-not $NoOrigin) { git -C $repoRoot remote add origin $OriginUrl }
        }

        $script:SavedEnv = @{
            XDG_CONFIG_HOME   = $env:XDG_CONFIG_HOME
            CLAUDE_PLANS_REPO = $env:CLAUDE_PLANS_REPO
            __CODE_ROOT       = $env:__CODE_ROOT
        };
        $env:XDG_CONFIG_HOME = $configHome;
        $env:CLAUDE_PLANS_REPO = $null;
        $env:__CODE_ROOT = $codeRoot;

        return [pscustomobject]@{
            Base       = $base
            CodeRoot   = $codeRoot
            RepoRoot   = $repoRoot
            PlansRepo  = $plansRepo
            PlanDir    = Join-Path $plansRepo 'widget'
            ConfigHome = $configHome
            ConfigPath = Join-Path $configHome 'claude-planning/config.json'
        }
    }

    function Set-PlanConfig($Fixture, [string]$Json)
    {
        New-Item -ItemType Directory -Path (Split-Path $Fixture.ConfigPath -Parent) -Force | Out-Null;
        $Json | Set-Content -LiteralPath $Fixture.ConfigPath;
    }

    function New-PlanFile
    {
        param($Fixture, [string]$Name, [string]$Status = 'PLANNING', [string]$Branch, [string]$Title = 'a plan', [string]$Updated = '2026-09-01')

        New-Item -ItemType Directory -Path $Fixture.PlanDir -Force | Out-Null;
        $lines = @("# Plan: $Title", '', "Status: $Status");
        # An empty -Updated writes no Updated: line at all, so a test can cover a plan that
        # never got one.
        if ($Updated) { $lines += "Updated: $Updated" }
        if ($Branch) { $lines += "Branch: $Branch" }
        $lines += @('', '## Goal', '', 'something');
        $lines -join "`n" | Set-Content -LiteralPath (Join-Path $Fixture.PlanDir $Name);
    }

    function Invoke-Context($Fixture, [hashtable]$Extra = @{})
    {
        $args = @{ Path = $Fixture.RepoRoot } + $Extra;
        return (& $script:ScriptPath @args | ConvertFrom-Json);
    }
}

Describe 'Get-PlanContext' {

    AfterEach {
        if ($script:SavedEnv)
        {
            $env:XDG_CONFIG_HOME = $script:SavedEnv.XDG_CONFIG_HOME;
            $env:CLAUDE_PLANS_REPO = $script:SavedEnv.CLAUDE_PLANS_REPO;
            $env:__CODE_ROOT = $script:SavedEnv.__CODE_ROOT;
            $script:SavedEnv = $null;
        }
    }

    Context 'repository identity' {

        It 'names the repository from the origin remote rather than the directory' {
            $f = New-Fixture -OriginUrl 'git@gitlab-test:group/renamed.git';
            $context = Invoke-Context $f;

            $context.RepoName | Should -Be 'renamed';
        }

        It 'strips a trailing .git from an https origin' {
            $f = New-Fixture -OriginUrl 'https://example.com/group/widget.git';
            (Invoke-Context $f).RepoName | Should -Be 'widget';
        }

        It 'falls back to the work tree name when there is no origin' {
            $f = New-Fixture -NoOrigin;
            (Invoke-Context $f).RepoName | Should -Be 'widget';
        }

        It 'maps a linked worktree to the same plan directory as its main work tree' {
            $f = New-Fixture -NoOrigin;
            $worktree = Join-Path $f.CodeRoot 'widget-feature';
            git -C $f.RepoRoot worktree add --quiet -b feature $worktree | Out-Null;

            $fromWorktree = & $script:ScriptPath -Path $worktree | ConvertFrom-Json;

            $fromWorktree.RepoName | Should -Be 'widget';
            $fromWorktree.PlanDir | Should -Be (Invoke-Context $f).PlanDir;
            $fromWorktree.Branch | Should -Be 'feature';
        }

        It 'throws outside a git work tree' {
            $f = New-Fixture -NoGit;
            { & $script:ScriptPath -Path $f.RepoRoot } | Should -Throw -ExpectedMessage '*not inside a git work tree*';
        }
    }

    Context 'plans repository resolution' {

        It 'defaults to plans under the code root' {
            $f = New-Fixture;
            (Invoke-Context $f).PlansRepo | Should -Be (Join-Path $f.CodeRoot 'plans');
        }

        It 'takes plansRepo from the config file' {
            $f = New-Fixture;
            $configured = (Join-Path $f.Base 'elsewhere') -replace '\\', '/';
            Set-PlanConfig $f "{ `"plansRepo`": `"$configured`" }";

            (Invoke-Context $f).PlansRepo | Should -Be $configured;
        }

        It 'lets CLAUDE_PLANS_REPO override the config file' {
            $f = New-Fixture;
            $configured = (Join-Path $f.Base 'from-config') -replace '\\', '/';
            Set-PlanConfig $f "{ `"plansRepo`": `"$configured`" }";
            $env:CLAUDE_PLANS_REPO = Join-Path $f.Base 'from-env';

            (Invoke-Context $f).PlansRepo | Should -Be (Join-Path $f.Base 'from-env');
        }

        It 'expands a leading ~ in a configured path' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "plansRepo": "~/some-plans" }';

            (Invoke-Context $f).PlansRepo |
                Should -Be (Join-Path ([System.Environment]::GetFolderPath('UserProfile')) 'some-plans');
        }

        It 'throws on a config file that is not valid JSON' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ not json';

            { Invoke-Context $f } | Should -Throw -ExpectedMessage '*not valid JSON*';
        }
    }

    Context 'choosing the current plan' {

        It 'reports no plan when the plan directory does not exist' {
            $f = New-Fixture;
            $context = Invoke-Context $f;

            $context.PlanPath | Should -BeNullOrEmpty;
            $context.PlanMatch | Should -Be 'none';
            $context.Candidates | Should -BeNullOrEmpty;
        }

        It 'matches the plan whose Branch line is the checked-out branch' {
            $f = New-Fixture -NoOrigin -Branch 'kbi/feature';
            New-PlanFile $f -Name '2026-08-01-old.md' -Status 'DONE' -Branch 'kbi/old';
            New-PlanFile $f -Name '2026-09-01-feature.md' -Status 'PLANNING' -Branch 'kbi/feature';
            New-PlanFile $f -Name '2026-09-02-other.md' -Status 'PLANNING';

            $context = Invoke-Context $f;

            $context.PlanMatch | Should -Be 'branch';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-01-feature.md';
        }

        It 'falls back to the single active plan when no Branch line matches' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-08-01-spent.md' -Status 'DONE';
            New-PlanFile $f -Name '2026-09-01-current.md' -Status 'PLANNING';

            $context = Invoke-Context $f;

            $context.PlanMatch | Should -Be 'only-active';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-01-current.md';
        }

        It 'treats an IMPLEMENTING plan as active' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-running.md' -Status 'IMPLEMENTING';

            (Invoke-Context $f).PlanMatch | Should -Be 'only-active';
        }

        It 'refuses to choose between two active plans, and returns both' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-one.md' -Status 'PLANNING' -Title 'one';
            New-PlanFile $f -Name '2026-09-02-two.md' -Status 'PLANNING' -Title 'two';

            $context = Invoke-Context $f;

            $context.PlanMatch | Should -Be 'ambiguous';
            $context.PlanPath | Should -BeNullOrEmpty;
            @($context.Candidates).Count | Should -Be 2;
            @($context.Candidates.Title) | Should -Contain 'one';
        }

        It 'reports every candidate with its header fields' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-one.md' -Status 'DONE' -Branch 'kbi/one' -Title 'the first plan' -Updated '2026-09-01';

            $candidate = @((Invoke-Context $f).Candidates)[0];

            $candidate.Name | Should -Be '2026-09-01-one.md';
            $candidate.Title | Should -Be 'the first plan';
            $candidate.Status | Should -Be 'DONE';
            $candidate.Branch | Should -Be 'kbi/one';
            $candidate.Updated | Should -Be '2026-09-01';
        }
    }

    Context 'new plan paths' {

        It 'derives a dated, slugged path from the title' {
            $f = New-Fixture;
            $context = Invoke-Context $f @{ Title = 'Move plans into their OWN repo!' };
            $today = Get-Date -Format 'yyyy-MM-dd';

            Split-Path $context.NewPlanPath -Leaf | Should -Be "$today-move-plans-into-their-own-repo.md";
            Split-Path $context.NewPlanPath -Parent | Should -Be $context.PlanDir;
        }

        It 'stamps the path with -Date instead of today when placing an older plan' {
            $f = New-Fixture;
            $context = Invoke-Context $f @{ Title = 'an older plan'; Date = '2026-07-04' };

            Split-Path $context.NewPlanPath -Leaf | Should -Be '2026-07-04-an-older-plan.md';
        }

        It 'suffixes the name when the dated slug is already taken' {
            $f = New-Fixture;
            $today = Get-Date -Format 'yyyy-MM-dd';
            New-PlanFile $f -Name "$today-same-title.md" -Status 'DONE';

            $context = Invoke-Context $f @{ Title = 'same title' };

            Split-Path $context.NewPlanPath -Leaf | Should -Be "$today-same-title-2.md";
        }

        It 'creates nothing on disk' {
            $f = New-Fixture;
            $context = Invoke-Context $f @{ Title = 'nothing yet' };

            Test-Path -LiteralPath $context.NewPlanPath | Should -BeFalse;
            Test-Path -LiteralPath $context.PlanDir | Should -BeFalse;
        }

        It 'omits NewPlanPath without a title' {
            $f = New-Fixture;
            (Invoke-Context $f).NewPlanPath | Should -BeNullOrEmpty;
        }
    }

    Context 'hooks' {

        It 'reads a skill hook' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "surface": { "skill": "show-me" }, "worktree": { "skill": "new-branch-or-worktree" } }';
            $context = Invoke-Context $f;

            $context.Surface.Skill | Should -Be 'show-me';
            $context.Worktree.Skill | Should -Be 'new-branch-or-worktree';
        }

        It 'reads the session hook /oimpl opens the new session with' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "session": { "command": "wezterm start --cwd {path}" } }';

            (Invoke-Context $f).Session.Command | Should -Be 'wezterm start --cwd {path}';
        }

        It 'reads a command hook' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "surface": { "command": "open {path}" } }';

            (Invoke-Context $f).Surface.Command | Should -Be 'open {path}';
        }

        It 'accepts a bare string as the command form' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "surface": "open {path}" }';

            (Invoke-Context $f).Surface.Command | Should -Be 'open {path}';
        }

        It 'prefers the command when a hook names both' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "surface": { "skill": "show-me", "command": "open {path}" } }';
            $context = Invoke-Context $f;

            $context.Surface.Command | Should -Be 'open {path}';
            $context.Surface.PSObject.Properties.Name | Should -Not -Contain 'Skill';
        }

        It 'reports an unconfigured hook as absent' {
            $f = New-Fixture;
            Set-PlanConfig $f '{ "plansRepo": "/tmp/plans" }';
            $context = Invoke-Context $f;

            $context.Surface | Should -BeNullOrEmpty;
            $context.Worktree | Should -BeNullOrEmpty;
            $context.Session | Should -BeNullOrEmpty;
        }

        It 'reports every hook as absent when there is no config file at all' {
            $f = New-Fixture;
            $context = Invoke-Context $f;

            $context.ConfigExists | Should -BeFalse;
            $context.Surface | Should -BeNullOrEmpty;
            $context.Worktree | Should -BeNullOrEmpty;
            $context.Session | Should -BeNullOrEmpty;
        }
    }

    Context 'plan keys' {

        It 'hands out keys in listing order and skips spent plans' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-08-01-spent.md' -Status 'DONE' -Updated '2026-08-01';
            New-PlanFile $f -Name '2026-08-02-odd.md' -Status 'DRAFT' -Updated '2026-08-02';
            New-PlanFile $f -Name '2026-09-01-early.md' -Status 'PLANNING' -Updated '2026-09-01';
            New-PlanFile $f -Name '2026-09-02-late.md' -Status 'PLANNING' -Updated '2026-09-05';
            New-PlanFile $f -Name '2026-09-03-running.md' -Status 'IMPLEMENTING' -Updated '2026-09-03';
            # No Updated: line at all. Its name would put it last among the not-started
            # plans, so its position proves the missing date is what sorts it, not the name.
            New-PlanFile $f -Name '2026-09-04-undated.md' -Status 'PLANNING' -Updated '';

            $candidates = @((Invoke-Context $f).Candidates);

            @($candidates.Name) | Should -Be @(
                '2026-08-01-spent.md',
                '2026-08-02-odd.md',
                '2026-09-04-undated.md',
                '2026-09-01-early.md',
                '2026-09-02-late.md',
                '2026-09-03-running.md'
            );
            @($candidates.Key) | Should -Be @($null, 'A', 'B', 'C', 'D', 'E');
        }

        It 'sorts a plan with no Updated line first within its group' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-dated.md' -Status 'PLANNING' -Updated '2026-09-01';
            New-PlanFile $f -Name '2026-09-02-undated.md' -Status 'PLANNING' -Updated '';

            $candidates = @((Invoke-Context $f).Candidates);

            $candidates[0].Name | Should -Be '2026-09-02-undated.md';
            $candidates[0].Updated | Should -BeNullOrEmpty;
            $candidates[0].Key | Should -Be 'A';
        }

        It 'gives a spent plan no key at all' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-08-01-spent.md' -Status 'DONE';

            @((Invoke-Context $f).Candidates)[0].Key | Should -BeNullOrEmpty;
        }

        It 'continues past Z so the 27th unfinished plan is AA' {
            $f = New-Fixture;
            1..27 | ForEach-Object {
                New-PlanFile $f -Name ('2026-09-01-p{0:d2}.md' -f $_) -Status 'PLANNING' -Updated '2026-09-01';
            }

            $candidates = @((Invoke-Context $f).Candidates);

            ($candidates | Where-Object { $_.Name -eq '2026-09-01-p01.md' }).Key | Should -Be 'A';
            ($candidates | Where-Object { $_.Name -eq '2026-09-01-p26.md' }).Key | Should -Be 'Z';
            ($candidates | Where-Object { $_.Name -eq '2026-09-01-p27.md' }).Key | Should -Be 'AA';
        }

        It 'emits Matches as an empty array when no selector was passed' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-one.md' -Status 'PLANNING';

            $raw = & $script:ScriptPath -Path $f.RepoRoot;

            ($raw -join "`n") | Should -Match '"Matches":\s*\[\s*\]';
            @((Invoke-Context $f).Matches).Count | Should -Be 0;
        }
    }

    Context 'selecting a plan' {

        BeforeEach {
            $script:Letters = {
                param($Fixture)

                New-PlanFile $Fixture -Name '2026-09-01-alpha.md' -Status 'PLANNING' -Title 'the alpha plan' -Updated '2026-09-01';
                New-PlanFile $Fixture -Name '2026-09-02-bravo.md' -Status 'PLANNING' -Title 'the bravo plan' -Updated '2026-09-02';
                New-PlanFile $Fixture -Name '2026-09-03-charlie.md' -Status 'PLANNING' -Title 'the charlie plan' -Updated '2026-09-03';
                New-PlanFile $Fixture -Name '2026-09-04-delta.md' -Status 'PLANNING' -Title 'the delta plan' -Updated '2026-09-04';
            };
        }

        It 'resolves a key case-insensitively' {
            $f = New-Fixture;
            & $script:Letters $f;

            $context = Invoke-Context $f @{ Plan = 'd' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-04-delta.md';
            @($context.Matches).Count | Should -Be 1;

            # A lone match must still come out as a JSON array, not an unrolled object.
            $raw = (& $script:ScriptPath -Path $f.RepoRoot -Plan 'd') -join "`n";
            $raw | Should -Match '"Matches":\s*\[\s*\{';
        }

        It 'resolves a file name' {
            $f = New-Fixture;
            & $script:Letters $f;

            $context = Invoke-Context $f @{ Plan = '2026-09-02-bravo.md' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-02-bravo.md';
        }

        It 'resolves a file name given without the .md suffix' {
            $f = New-Fixture;
            & $script:Letters $f;

            $context = Invoke-Context $f @{ Plan = '2026-09-02-bravo' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-02-bravo.md';
        }

        It 'resolves a substring of the title' {
            $f = New-Fixture;
            & $script:Letters $f;

            $context = Invoke-Context $f @{ Plan = 'CHARLIE plan' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-03-charlie.md';
        }

        It 'reports ambiguous and lists every plan a substring hits' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-retry-budget.md' -Status 'PLANNING' -Title 'retry budget';
            New-PlanFile $f -Name '2026-09-02-retry-limits.md' -Status 'PLANNING' -Title 'retry limits';
            New-PlanFile $f -Name '2026-09-03-other.md' -Status 'PLANNING' -Title 'something else';

            $context = Invoke-Context $f @{ Plan = 'retry' };

            $context.PlanMatch | Should -Be 'ambiguous';
            $context.PlanPath | Should -BeNullOrEmpty;
            @($context.Matches).Count | Should -Be 2;
            @($context.Matches.Name) | Should -Contain '2026-09-01-retry-budget.md';
            @($context.Matches.Name) | Should -Contain '2026-09-02-retry-limits.md';
        }

        It 'reports no-match with a null plan path when nothing matches' {
            $f = New-Fixture;
            & $script:Letters $f;

            $context = Invoke-Context $f @{ Plan = 'add a retry budget' };

            $context.PlanMatch | Should -Be 'no-match';
            $context.PlanPath | Should -BeNullOrEmpty;
            @($context.Matches).Count | Should -Be 0;
        }

        It 'beats a Branch line that names another plan' {
            $f = New-Fixture -NoOrigin -Branch 'kbi/feature';
            New-PlanFile $f -Name '2026-09-01-feature.md' -Status 'PLANNING' -Branch 'kbi/feature' -Title 'the feature';
            New-PlanFile $f -Name '2026-09-02-elsewhere.md' -Status 'PLANNING' -Title 'somewhere else';

            (Invoke-Context $f).PlanMatch | Should -Be 'branch';

            $context = Invoke-Context $f @{ Plan = 'elsewhere' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-02-elsewhere.md';
        }

        It 'selects a spent plan by name even though it has no key' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-08-01-spent.md' -Status 'DONE' -Title 'a spent plan';
            New-PlanFile $f -Name '2026-09-01-current.md' -Status 'PLANNING' -Title 'the current plan';

            $context = Invoke-Context $f @{ Plan = '2026-08-01-spent.md' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-08-01-spent.md';
            @($context.Matches)[0].Key | Should -BeNullOrEmpty;
        }

        It 'prefers an exact key over a name that contains the same letter' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-alpha.md' -Status 'PLANNING' -Title 'alpha' -Updated '2026-09-01';
            New-PlanFile $f -Name '2026-09-02-a-second.md' -Status 'PLANNING' -Title 'a second' -Updated '2026-09-02';

            $context = Invoke-Context $f @{ Plan = 'A' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be '2026-09-01-alpha.md';
        }

        It 'prefers an exact name over the longer names that contain it' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'retry.md' -Status 'PLANNING' -Title 'retry' -Updated '2026-09-01';
            New-PlanFile $f -Name 'retry-budget.md' -Status 'PLANNING' -Title 'retry budget' -Updated '2026-09-02';

            $context = Invoke-Context $f @{ Plan = 'retry' };

            $context.PlanMatch | Should -Be 'selected';
            Split-Path $context.PlanPath -Leaf | Should -Be 'retry.md';
            @($context.Matches).Count | Should -Be 1;
        }

        It 'reports no-match when the repository has no plans at all' {
            $f = New-Fixture;

            $context = Invoke-Context $f @{ Plan = 'anything' };

            $context.PlanMatch | Should -Be 'no-match';
            $context.PlanPath | Should -BeNullOrEmpty;
            @($context.Matches).Count | Should -Be 0;
        }

        It 'reports no-match for a key when every plan is spent and so keyless' {
            $f = New-Fixture;
            # Digits only, apart from the `.md` suffix every plan file must carry, and
            # numeric titles: the only letters anywhere in this fixture are `m` and `d`, so
            # the selector `A` cannot match as a substring either. What is left to match on
            # is the key, and a spent plan has none.
            New-PlanFile $f -Name '2026-08-01.md' -Status 'DONE' -Title '1';
            New-PlanFile $f -Name '2026-08-02.md' -Status 'DONE' -Title '2';

            $raw = (& $script:ScriptPath -Path $f.RepoRoot -Plan 'A') -join "`n";
            $context = $raw | ConvertFrom-Json;

            $context.PlanMatch | Should -Be 'no-match';
            $context.PlanPath | Should -BeNullOrEmpty;
            $raw | Should -Match '"Matches":\s*\[\s*\]';
        }

        It 'falls back to the branch rules when the selector is empty' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-current.md' -Status 'PLANNING';

            (Invoke-Context $f @{ Plan = '' }).PlanMatch | Should -Be 'only-active';
        }
    }
}
