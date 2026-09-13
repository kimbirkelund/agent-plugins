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
        $lines = @("# Plan: $Title", '', "Status: $Status", "Updated: $Updated");
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
}
