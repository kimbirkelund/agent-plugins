BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-PlanList.ps1';

    # One git config for the whole file, so no repository needs its own identity or
    # commit.gpgsign setting and the developer's ~/.gitconfig is never read.
    $script:SavedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL;
    $gitConfig = Join-Path $TestDrive 'gitconfig';
    Set-Content -LiteralPath $gitConfig -Value "[user]`n`tname = Test User`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n";
    $env:GIT_CONFIG_GLOBAL = $gitConfig;

    function New-RepoTemplate
    {
        param([string]$Path, [string]$Branch)

        New-Item -ItemType Directory -Path $Path -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $Path 'file.txt');
        git -C $Path init --quiet --initial-branch=$Branch;
        git -C $Path add -A;
        git -C $Path commit --quiet -m 'initial';
        git -C $Path remote add origin 'git@gitlab-test:group/widget.git';
    }

    # The template repository for the default branch, built once and copied per test;
    # never handed to a test.
    $script:RepoTemplates = @{};
    $dir = Join-Path $TestDrive 'template-main';
    New-RepoTemplate -Path $dir -Branch 'main';
    $script:RepoTemplates['main'] = $dir;

    function New-Fixture
    {
        param([string]$Branch = 'main')

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $plansRepo = Join-Path $codeRoot 'plans';
        $configHome = Join-Path $base 'config';

        New-Item -ItemType Directory -Path $codeRoot -Force | Out-Null;
        New-Item -ItemType Directory -Path $configHome -Force | Out-Null;

        # A fresh copy of the template for this branch; its origin URL holds no path.
        $template = $script:RepoTemplates[$Branch];
        if ($template)
        {
            Copy-Item -LiteralPath $template -Destination $repoRoot -Recurse;
        }
        else
        {
            New-RepoTemplate -Path $repoRoot -Branch $Branch;
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
            Base      = $base
            CodeRoot  = $codeRoot
            RepoRoot  = $repoRoot
            PlansRepo = $plansRepo
            PlanDir   = Join-Path $plansRepo 'widget'
        }
    }

    function New-PlanFile
    {
        param(
            $Fixture,
            [string]$Name,
            [string]$Status = 'PLANNING',
            [string]$Branch,
            [string]$Title = 'a plan',
            [string]$Updated = '2026-09-01',
            [string]$Goal = 'ship the thing.',
            [int]$Steps = 0,
            [string[]]$OpenQuestions = @(),
            [string[]]$Markers = @(),
            [switch]$ListForm
        )

        New-Item -ItemType Directory -Path $Fixture.PlanDir -Force | Out-Null;

        $m = if ($ListForm) { '- ' } else { '' };
        $lines = @("# Plan: $Title", '', "${m}Status: $Status");
        # An empty -Updated writes no Updated: line at all, so a test can cover a plan that
        # never got one — the one header field that crosses JSON as null.
        if ($Updated) { $lines += "${m}Updated: $Updated" }
        if ($Branch) { $lines += "${m}Branch: $Branch" }
        $lines += @('', '## Goal', '', $Goal, '', '## Steps', '');
        for ($i = 1; $i -le $Steps; $i++) { $lines += "$i. do thing $i" }
        $lines += @('', '## Open questions', '');
        $lines += $OpenQuestions;
        foreach ($marker in $Markers) { $lines += "$([char]0x222B)$([char]0x222B)$marker$([char]0x222B)$([char]0x222B)" }

        $lines -join "`n" | Set-Content -LiteralPath (Join-Path $Fixture.PlanDir $Name);
    }

    function Invoke-List($Fixture, [hashtable]$Extra = @{})
    {
        $arguments = @{ Path = $Fixture.RepoRoot } + $Extra;
        return (& $script:ScriptPath @arguments | ConvertFrom-Json);
    }
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal;
}

Describe 'Get-PlanList' {

    AfterEach {
        if ($script:SavedEnv)
        {
            $env:XDG_CONFIG_HOME = $script:SavedEnv.XDG_CONFIG_HOME;
            $env:CLAUDE_PLANS_REPO = $script:SavedEnv.CLAUDE_PLANS_REPO;
            $env:__CODE_ROOT = $script:SavedEnv.__CODE_ROOT;
            $script:SavedEnv = $null;
        }
    }

    Context 'what is listed' {

        It 'leaves out spent plans by default' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-old.md' -Status 'DONE';
            New-PlanFile $f -Name '2026-09-02-live.md' -Status 'PLANNING';

            $result = Invoke-List $f;

            @($result.Plans).Count | Should -Be 1;
            $result.Plans[0].Name | Should -Be '2026-09-02-live.md';
            $result.IncludedDone | Should -BeFalse;
        }

        It 'includes spent plans with -All' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-old.md' -Status 'DONE';
            New-PlanFile $f -Name '2026-09-02-live.md' -Status 'PLANNING';

            $result = Invoke-List $f @{ All = $true };

            @($result.Plans).Count | Should -Be 2;
            $result.IncludedDone | Should -BeTrue;
        }

        It 'counts every plan in Total and only the listed ones in Listed' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-old.md' -Status 'DONE';
            New-PlanFile $f -Name '2026-09-02-live.md' -Status 'PLANNING';

            $result = Invoke-List $f;

            $result.Total | Should -Be 2;
            $result.Listed | Should -Be 1;
        }

        It 'never hides a plan whose status is unrecognised' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-01-odd.md' -Status 'FINISHED?';

            $result = Invoke-List $f;

            @($result.Plans).Count | Should -Be 1;
            $result.Plans[0].Group | Should -Be 'unknown';
        }

        It 'reports an empty list for a repository with no plans at all' {
            $f = New-Fixture;

            $result = Invoke-List $f;

            $result.Total | Should -Be 0;
            $result.Listed | Should -Be 0;
            @($result.Plans).Count | Should -Be 0;
            $result.PlanDir | Should -Be $f.PlanDir;
        }

        It 'flags the current plan' {
            $f = New-Fixture;
            New-PlanFile $f -Name '2026-09-02-live.md' -Status 'PLANNING' -Branch 'main';

            $result = Invoke-List $f;

            $result.Plans[0].IsCurrent | Should -BeTrue;
            $result.CurrentPlan | Should -Be $result.Plans[0].Path;
        }
    }

    Context 'order' {

        It 'puts spent plans first, then not-started, and the ones in flight last' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'a-ongoing.md' -Status 'IMPLEMENTING' -Updated '2026-09-01';
            New-PlanFile $f -Name 'b-done.md' -Status 'DONE' -Updated '2026-09-02';
            New-PlanFile $f -Name 'c-planning.md' -Status 'PLANNING' -Updated '2026-09-03';

            $result = Invoke-List $f @{ All = $true };

            @($result.Plans | ForEach-Object { $_.Group }) | Should -Be @('done', 'not-started', 'ongoing');
        }

        It 'puts an unrecognised status between spent and not-started' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'a-odd.md' -Status 'WAT';
            New-PlanFile $f -Name 'b-done.md' -Status 'DONE';
            New-PlanFile $f -Name 'c-planning.md' -Status 'PLANNING';

            $result = Invoke-List $f @{ All = $true };

            @($result.Plans | ForEach-Object { $_.Group }) | Should -Be @('done', 'unknown', 'not-started');
        }

        It 'puts the least recently updated plan of a group first' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'newer.md' -Status 'PLANNING' -Updated '2026-09-09';
            New-PlanFile $f -Name 'older.md' -Status 'PLANNING' -Updated '2026-09-02';

            $result = Invoke-List $f;

            @($result.Plans | ForEach-Object { $_.Name }) | Should -Be @('older.md', 'newer.md');
        }

        It 'falls back to the file name when two plans share an Updated date' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'b.md' -Status 'PLANNING' -Updated '2026-09-02';
            New-PlanFile $f -Name 'a.md' -Status 'PLANNING' -Updated '2026-09-02';

            $result = Invoke-List $f;

            @($result.Plans | ForEach-Object { $_.Name }) | Should -Be @('a.md', 'b.md');
        }

        It 'lists the plans in the order the context script handed the keys out' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'a-ongoing.md' -Status 'IMPLEMENTING' -Updated '2026-09-01';
            New-PlanFile $f -Name 'b-done.md' -Status 'DONE' -Updated '2026-09-02';
            New-PlanFile $f -Name 'c-planning.md' -Status 'PLANNING' -Updated '2026-09-03';
            New-PlanFile $f -Name 'd-odd.md' -Status 'WAT' -Updated '2026-09-04';
            # No Updated: line, so the field arrives from the context script as JSON null.
            # Both sorts must still agree on where it goes: first within its own group, and
            # its name would otherwise put it last among the not-started plans.
            New-PlanFile $f -Name 'e-undated.md' -Status 'PLANNING' -Updated '';

            $result = Invoke-List $f @{ All = $true };

            @($result.Plans | ForEach-Object { $_.Name }) |
                Should -Be @('b-done.md', 'd-odd.md', 'e-undated.md', 'c-planning.md', 'a-ongoing.md');
            @($result.Plans | ForEach-Object { $_.Key }) | Should -Be @($null, 'A', 'B', 'C', 'D');
        }

        It 'keeps the letters ascending when spent plans are left out' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'a-spent.md' -Status 'DONE' -Updated '2026-09-01';
            New-PlanFile $f -Name 'b-early.md' -Status 'PLANNING' -Updated '2026-09-02';
            New-PlanFile $f -Name 'c-late.md' -Status 'PLANNING' -Updated '2026-09-03';
            New-PlanFile $f -Name 'd-running.md' -Status 'IMPLEMENTING' -Updated '2026-09-04';

            $result = Invoke-List $f;

            @($result.Plans | ForEach-Object { $_.Name }) |
                Should -Be @('b-early.md', 'c-late.md', 'd-running.md');
            @($result.Plans | ForEach-Object { $_.Key }) | Should -Be @('A', 'B', 'C');
        }
    }

    Context 'per-plan detail' {

        It 'reads the header through' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -Title 'rework the parser' -Status 'IMPLEMENTING' -Branch 'feat/parser' -Updated '2026-09-07';

            $plan = (Invoke-List $f).Plans[0];

            $plan.Title | Should -Be 'rework the parser';
            $plan.Status | Should -Be 'IMPLEMENTING';
            $plan.Group | Should -Be 'ongoing';
            $plan.Branch | Should -Be 'feat/parser';
            $plan.Updated | Should -Be '2026-09-07';
            $plan.Key | Should -Be 'A';
        }

        It 'leaves a spent plan without a key' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'spent.md' -Status 'DONE';

            (Invoke-List $f @{ All = $true }).Plans[0].Key | Should -BeNullOrEmpty;
        }

        It 'takes the goal as one rewrapped paragraph' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -Goal "make the thing fast,`nwithout breaking it.`n`nA second paragraph nobody needs.";

            (Invoke-List $f).Plans[0].Goal | Should -Be 'make the thing fast, without breaking it.';
        }

        It 'counts the numbered steps' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -Steps 4;

            (Invoke-List $f).Plans[0].Steps | Should -Be 4;
        }

        It 'counts unconsumed markers' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -Markers @('why not reuse the parser?', 'split this in two');

            (Invoke-List $f).Plans[0].Markers | Should -Be 2;
        }

        It 'counts what stands under open questions' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('- which database?', '- who owns the migration?');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 2;
        }

        It 'reads a list-form plan the same as the bare form' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'a-list.md' -Status 'IMPLEMENTING' -Branch 'kbi/x' -Title 'same' -Updated '2026-09-05' -ListForm;

            $p = (Invoke-List $f).Plans[0];

            $p.Status | Should -Be 'IMPLEMENTING';
            $p.Title | Should -Be 'same';
            $p.Updated | Should -Be '2026-09-05';
        }

        It 'counts an open question wrapped over three lines as a list item once' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('- which database should we', '  pick for the store, given', '  the latency budget?');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 1;
        }

        It 'counts two wrapped paragraphs separated by a blank line as two' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('which database should we', 'pick for the store?', '', 'who owns the', 'migration?');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 2;
        }

        It 'counts numbered open questions once per item' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('1. which database?', '2. who owns the', '   migration?', '3. when do we ship?');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 3;
        }

        It 'counts an indented nested item as part of the entry above' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('- which database?', '  - postgres', '  - sqlite', '- who owns it?');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 2;
        }

        It 'reads none under open questions as nothing standing' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md' -OpenQuestions @('none');

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 0;
        }

        It 'reads an empty open questions section as nothing standing' {
            $f = New-Fixture;
            New-PlanFile $f -Name 'p.md';

            (Invoke-List $f).Plans[0].OpenQuestions | Should -Be 0;
        }
    }
}
