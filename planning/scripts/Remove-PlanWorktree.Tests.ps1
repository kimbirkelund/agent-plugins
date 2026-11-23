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
}

Describe 'Remove-PlanWorktree' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));
        New-Item -ItemType Directory -Path $root | Out-Null;
        $origin = Join-Path $root 'origin.git';
        $main = Join-Path $root 'main';
        $other = Join-Path $root 'other';
        $plan = Join-Path $root 'plan';
        git init --bare -b main $origin *> $null;
        git clone $origin $main *> $null;
        Invoke-Git $main @('commit', '--allow-empty', '-m', 'init') | Out-Null;
        Invoke-Git $main @('push', 'origin', 'main') | Out-Null;
        Invoke-Git $main @('worktree', 'add', '-b', 'plan-branch', $plan) | Out-Null;
        $mainReal = Invoke-Git $main @('rev-parse', '--show-toplevel');
        $planReal = Invoke-Git $plan @('rev-parse', '--show-toplevel');

        # Advance origin/main from a second clone, so a pull has something to fetch.
        git clone $origin $other *> $null;
        Invoke-Git $other @('commit', '--allow-empty', '-m', 'merged') | Out-Null;
        Invoke-Git $other @('push', 'origin', 'main') | Out-Null;
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
