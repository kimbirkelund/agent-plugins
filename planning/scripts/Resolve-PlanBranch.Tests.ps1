BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Resolve-PlanBranch.ps1';

    function New-Fixture
    {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $planDir = Join-Path $codeRoot 'plans/widget';

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

        New-Item -ItemType Directory -Path $repoRoot, $planDir -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');
        git -C $repoRoot init --quiet --initial-branch=main;
        git -C $repoRoot config commit.gpgsign false;
        git -C $repoRoot add -A;
        git -C $repoRoot commit --quiet -m 'initial';

        return [pscustomobject]@{
            Base     = $base
            RepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
            PlanDir  = $planDir
        }
    }

    function Write-Plan($Fixture, [string]$Name, [string]$Title, [string]$Branch, [string]$Status = 'PLANNING')
    {
        $lines = @("# Plan: $Title", '', "Status: $Status");
        if ($Branch) { $lines += "Branch: $Branch" }
        $path = Join-Path $Fixture.PlanDir $Name;
        $lines | Set-Content -LiteralPath $path;
        return (Resolve-Path -LiteralPath $path).Path;
    }

    function Invoke-Resolve($Fixture, [string]$Plan, [string]$Branch)
    {
        $params = @{ Plan = $Plan; RepoRoot = $Fixture.RepoRoot };
        if ($Branch) { $params['Branch'] = $Branch }
        return (& $script:ScriptPath @params | ConvertFrom-Json);
    }
}

Describe 'Resolve-PlanBranch' {
    BeforeEach {
        $script:Fx = New-Fixture;
    }

    AfterEach {
        foreach ($name in $script:SavedEnv.Keys)
        {
            Set-Item -Path "env:$name" -Value $script:SavedEnv[$name] -ErrorAction SilentlyContinue;
            if ($null -eq $script:SavedEnv[$name]) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
        }
    }

    Context 'without -Branch' {
        It 'reports new when the plan has no Branch line' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;

            $r = Invoke-Resolve $script:Fx $plan;

            $r.Mode | Should -Be 'new';
            $r.Branch | Should -BeNullOrEmpty;
            $r.Path | Should -BeNullOrEmpty;
        }

        It 'reports existing with the repo root when the branch is checked out in place' {
            git -C $script:Fx.RepoRoot switch --quiet -c feat;
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'feat';

            $r = Invoke-Resolve $script:Fx $plan;

            $r.Mode | Should -Be 'existing';
            $r.Branch | Should -Be 'feat';
            $r.Path | Should -Be $script:Fx.RepoRoot;
        }

        It 'falls back to the repo root when the branch exists but is checked out nowhere' {
            git -C $script:Fx.RepoRoot branch feat;
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'feat';

            $r = Invoke-Resolve $script:Fx $plan;

            $r.Mode | Should -Be 'existing';
            $r.Path | Should -Be $script:Fx.RepoRoot;
        }

        It 'reports the worktree path when the branch is checked out in a worktree' {
            $wt = Join-Path $script:Fx.Base 'feat-wt';
            git -C $script:Fx.RepoRoot worktree add --quiet -b feat $wt;
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'feat';

            $r = Invoke-Resolve $script:Fx $plan;

            $r.Mode | Should -Be 'existing';
            (Resolve-Path -LiteralPath $r.Path).Path | Should -Be (Resolve-Path -LiteralPath $wt).Path;
        }

        It 'throws when the named branch does not exist' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'ghost';

            { Invoke-Resolve $script:Fx $plan } | Should -Throw '*ghost*does not exist*';
        }

        It 'throws naming the plan file when another plan has the same branch' {
            git -C $script:Fx.RepoRoot branch feat;
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'feat';
            Write-Plan $script:Fx 'b.md' 'Beta' 'feat' | Out-Null;

            { Invoke-Resolve $script:Fx $plan } | Should -Throw '*a.md*feat*b.md*';
        }
    }

    Context 'with -Branch' {
        It 'reports new when no plan owns the branch' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;
            Write-Plan $script:Fx 'b.md' 'Beta' 'other' | Out-Null;

            $r = Invoke-Resolve $script:Fx $plan 'fresh';

            $r.Mode | Should -Be 'new';
            $r.Branch | Should -Be 'fresh';
            $r.Path | Should -BeNullOrEmpty;
        }

        It 'throws naming the owner when another plan has the branch' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;
            Write-Plan $script:Fx 'b.md' 'Beta' 'taken' | Out-Null;

            { Invoke-Resolve $script:Fx $plan 'taken' } | Should -Throw '*b.md*Beta*';
        }

        It 'throws when the owner is a DONE plan' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;
            Write-Plan $script:Fx 'b.md' 'Beta' 'taken' 'DONE' | Out-Null;

            { Invoke-Resolve $script:Fx $plan 'taken' } | Should -Throw '*taken*b.md*';
        }

        It 'throws when the plan already names a branch' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' 'mine';

            { Invoke-Resolve $script:Fx $plan 'fresh' } | Should -Throw '*a.md*already names branch*mine*';
        }
    }

    Context 'normalisation' {
        It 'matches an owner when -Branch carries whitespace and a refs/heads prefix' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;
            Write-Plan $script:Fx 'b.md' 'Beta' 'taken' | Out-Null;

            { Invoke-Resolve $script:Fx $plan ' refs/heads/taken ' } | Should -Throw '*taken*b.md*';
        }

        It 'emits the normalised branch' {
            $plan = Write-Plan $script:Fx 'a.md' 'Alpha' $null;

            $r = Invoke-Resolve $script:Fx $plan ' refs/heads/fresh ';

            $r.Branch | Should -Be 'fresh';
        }

        It 'does not clash with itself when the plan is reached through a symlink' {
            git -C $script:Fx.RepoRoot branch feat;
            Write-Plan $script:Fx 'a.md' 'Alpha' 'feat' | Out-Null;
            $link = Join-Path $script:Fx.Base 'planlink';
            New-Item -ItemType SymbolicLink -Path $link -Target $script:Fx.PlanDir | Out-Null;

            $r = Invoke-Resolve $script:Fx (Join-Path $link 'a.md');

            $r.Mode | Should -Be 'existing';
            $r.Branch | Should -Be 'feat';
        }
    }

    Context 'guards' {
        It 'throws when the plan file does not exist' {
            $missing = Join-Path $script:Fx.PlanDir 'nope.md';

            { Invoke-Resolve $script:Fx $missing } | Should -Throw '*nope.md*does not exist*';
        }
    }
}
