BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Remove-PlanWorktree.ps1';
    $env:GIT_AUTHOR_NAME = 'Test'; $env:GIT_AUTHOR_EMAIL = 'test@example.com';
    $env:GIT_COMMITTER_NAME = 'Test'; $env:GIT_COMMITTER_EMAIL = 'test@example.com';

    function Invoke-Git
    {
        param([string] $Dir, [string[]] $GitArgs)
        $out = git -C $Dir @GitArgs 2>&1;
        if ($LASTEXITCODE -ne 0) { throw "git $GitArgs failed: $out" }
        $out;
    }

    function Invoke-Script
    {
        param([string] $Dir, [hashtable] $Params)
        Push-Location $Dir;
        try { (& $script:Script @Params) | ConvertFrom-Json }
        finally { Pop-Location }
    }

    # One git config for the whole file, so no repository needs its own identity and the
    # developer's ~/.gitconfig is never read.
    $script:SavedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL;
    $gitConfig = Join-Path $TestDrive 'gitconfig';
    Set-Content -LiteralPath $gitConfig -Value "[user]`n`tname = Test User`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n";
    $env:GIT_CONFIG_GLOBAL = $gitConfig;

    # The template, built once and copied per test; never handed to a test. It stops before
    # the worktree is added, since a worktree stores absolute gitdir paths.
    $script:Template = Join-Path $TestDrive 'template';
    New-Item -ItemType Directory -Path $script:Template | Out-Null;
    $tOrigin = Join-Path $script:Template 'origin.git';
    $tMain = Join-Path $script:Template 'main';
    $tOther = Join-Path $script:Template 'other';
    git init --bare -b main $tOrigin *> $null;
    git clone $tOrigin $tMain *> $null;
    Invoke-Git $tMain @('commit', '--allow-empty', '-m', 'init') | Out-Null;
    Invoke-Git $tMain @('push', 'origin', 'main') | Out-Null;
    # Advance origin/main from a second clone, so a pull has something to fetch.
    git clone $tOrigin $tOther *> $null;
    Invoke-Git $tOther @('commit', '--allow-empty', '-m', 'merged') | Out-Null;
    Invoke-Git $tOther @('push', 'origin', 'main') | Out-Null;
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal;
}

Describe 'Remove-PlanWorktree' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));
        $origin = Join-Path $root 'origin.git';
        $main = Join-Path $root 'main';
        $other = Join-Path $root 'other';
        $plan = Join-Path $root 'plan';

        # A fresh copy of the template (origin, main, and a second clone that advanced
        # origin/main), with each copied clone's remote URL set to the copied origin.
        Copy-Item -LiteralPath $script:Template -Destination $root -Recurse;
        foreach ($clone in $main, $other)
        {
            Invoke-Git $clone @('remote', 'set-url', 'origin', $origin) | Out-Null;
        }
        Invoke-Git $main @('worktree', 'add', '-b', 'plan-branch', $plan) | Out-Null;
        $mainReal = Invoke-Git $main @('rev-parse', '--show-toplevel');
        $planReal = Invoke-Git $plan @('rev-parse', '--show-toplevel');
    }

    It 'pulls the target and removes the worktree' {
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.RepoRoot | Should -Be $mainReal;
        $r.TargetPath | Should -Be $mainReal;
        $r.Pulled | Should -BeTrue;
        $r.WorktreePath | Should -Be $planReal;
        $r.Removed | Should -BeTrue;
        $r.PSObject.Properties.Name | Should -Not -Contain 'Reason';
        Test-Path $plan | Should -BeFalse;
        Invoke-Git $main @('log', '--format=%s', '-1') | Should -Be 'merged';
        $r.BranchDeleted | Should -BeTrue;
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -BeNullOrEmpty;
    }

    It 'pulls in the target worktree when run from the plan worktree' {
        $r = Invoke-Script $plan @{ Branch = 'plan-branch'; Target = 'main' };
        $r.RepoRoot | Should -Be $mainReal;
        $r.Pulled | Should -BeTrue;
        $r.Removed | Should -BeTrue;
    }

    It 'reports a target that is not checked out and still removes the worktree' {
        Invoke-Git $main @('switch', '-c', 'elsewhere') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.TargetPath | Should -BeNullOrEmpty;
        $r.Pulled | Should -BeFalse;
        $r.Removed | Should -BeTrue;
        $r.Reason | Should -Be 'target-not-checked-out';
    }

    It 'reports a failed pull and still removes the worktree' {
        Invoke-Git $main @('commit', '--allow-empty', '-m', 'diverge') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.Pulled | Should -BeFalse;
        $r.Removed | Should -BeTrue;
        $r.Reason | Should -Be 'pull-failed';
    }

    It 'leaves a dirty worktree in place' {
        Set-Content (Join-Path $plan 'untracked.txt') 'x';
        Invoke-Git $plan @('add', 'untracked.txt') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.Pulled | Should -BeTrue;
        $r.Removed | Should -BeFalse;
        $r.WorktreePath | Should -Be $planReal;
        $r.Reason | Should -Be 'dirty';
        $r.BranchDeleted | Should -BeFalse;
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
        $r.Message | Should -Not -BeNullOrEmpty;
        Test-Path $plan | Should -BeTrue;
    }

    It 'reports a locked worktree as remove-failed with git message' {
        Invoke-Git $main @('worktree', 'lock', $plan) | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.Removed | Should -BeFalse;
        $r.Reason | Should -Be 'remove-failed';
        $r.Message | Should -Match 'lock';
        $r.BranchDeleted | Should -BeFalse;
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
        Test-Path $plan | Should -BeTrue;
    }

    It 'never removes the main worktree' {
        $r = Invoke-Script $main @{ Branch = 'main'; Target = 'plan-branch' };
        $r.WorktreePath | Should -Be $mainReal;
        $r.Removed | Should -BeFalse;
        $r.Reason | Should -Match 'main-worktree';
        $r.BranchDeleted | Should -BeFalse;
        Invoke-Git $main @('branch', '--list', 'main') | Should -Not -BeNullOrEmpty;
        Test-Path $main | Should -BeTrue;
    }

    It 'reports a branch with no worktree' {
        $r = Invoke-Script $main @{ Branch = 'no-such-branch'; Target = 'main' };
        $r.WorktreePath | Should -BeNullOrEmpty;
        $r.Removed | Should -BeFalse;
        $r.Reason | Should -Be 'no-worktree';
        $r.BranchDeleted | Should -BeFalse;
    }

    It 'deletes an unmerged branch when MergedSha is its tip' {
        Invoke-Git $plan @('commit', '--allow-empty', '-m', 'squashed') | Out-Null;
        $tip = Invoke-Git $plan @('rev-parse', 'HEAD');
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main'; MergedSha = $tip };
        $r.Removed | Should -BeTrue;
        $r.BranchDeleted | Should -BeTrue;
        $r.PSObject.Properties.Name | Should -Not -Contain 'Reason';
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -BeNullOrEmpty;
    }

    It 'keeps a branch with a local commit beyond MergedSha' {
        Invoke-Git $plan @('commit', '--allow-empty', '-m', 'merged one') | Out-Null;
        $merged = Invoke-Git $plan @('rev-parse', 'HEAD');
        Invoke-Git $plan @('commit', '--allow-empty', '-m', 'local only') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main'; MergedSha = $merged };
        $r.Removed | Should -BeTrue;
        $r.BranchDeleted | Should -BeFalse;
        $r.Reason | Should -Match 'branch-not-merged';
        $r.Message | Should -Not -BeNullOrEmpty;
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
    }

    It 'keeps an unmerged branch when MergedSha is not passed' {
        Invoke-Git $plan @('commit', '--allow-empty', '-m', 'squashed') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main' };
        $r.BranchDeleted | Should -BeFalse;
        $r.Reason | Should -Be 'branch-not-merged';
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
    }

    It 'keeps an unmerged branch when MergedSha is a nonexistent object' {
        Invoke-Git $plan @('commit', '--allow-empty', '-m', 'squashed') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main'; MergedSha = ('deadbeef' * 5) };
        $r.Removed | Should -BeTrue;
        $r.BranchDeleted | Should -BeFalse;
        $r.Reason | Should -Match 'branch-not-merged';
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
    }

    It 'keeps a branch with no worktree under WhatIf' {
        Invoke-Git $main @('branch', 'lonely') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'lonely'; Target = 'main'; WhatIf = $true };
        $r.BranchDeleted | Should -BeFalse;
        Invoke-Git $main @('branch', '--list', 'lonely') | Should -Not -BeNullOrEmpty;
    }

    It 'deletes an existing branch that has no worktree' {
        Invoke-Git $main @('branch', 'lonely') | Out-Null;
        $r = Invoke-Script $main @{ Branch = 'lonely'; Target = 'main' };
        $r.BranchDeleted | Should -BeTrue;
        $r.Reason | Should -Be 'no-worktree';
        Invoke-Git $main @('branch', '--list', 'lonely') | Should -BeNullOrEmpty;
    }

    It 'changes nothing under WhatIf' {
        $before = Invoke-Git $main @('rev-parse', 'HEAD');
        $r = Invoke-Script $main @{ Branch = 'plan-branch'; Target = 'main'; WhatIf = $true };
        $r.Pulled | Should -BeFalse;
        $r.Removed | Should -BeFalse;
        $r.BranchDeleted | Should -BeFalse;
        Test-Path $plan | Should -BeTrue;
        Invoke-Git $main @('branch', '--list', 'plan-branch') | Should -Not -BeNullOrEmpty;
        Invoke-Git $main @('rev-parse', 'HEAD') | Should -Be $before;
    }
}
