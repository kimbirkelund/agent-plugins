#Requires -Modules Pester

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Archive-Sessions.ps1'

    function Get-EncodedName
    {
        param([string]$Path)

        return ($Path -replace '[^A-Za-z0-9]', '-')
    }

    function New-Fixture
    {
        param(
            [string]$Name,
            [string]$Branch = 'feature/thing',
            [string]$Origin = 'https://example.com/group/myrepo.git',
            [switch]$NoGit,
            [switch]$NoPlan
        )

        $root = Join-Path $TestDrive $Name
        $repo = Join-Path $root 'repo'
        $projects = Join-Path $root 'projects'
        $vault = Join-Path $root 'vault'
        # The plan lives in its own repository now, outside the work tree being archived.
        $plansRepo = Join-Path $root 'plans'
        $planDir = Join-Path $plansRepo 'myrepo'
        New-Item -ItemType Directory -Path $repo, $projects, $vault, $planDir -Force | Out-Null

        if (-not $NoGit)
        {
            git -C $repo init -q -b $Branch . 2>$null
            git -C $repo config user.email 'test@example.com' 2>$null
            git -C $repo config user.name 'Test' 2>$null
            git -C $repo config commit.gpgsign false 2>$null
            if ($Origin)
            {
                git -C $repo remote add origin $Origin 2>$null
            }
            Set-Content -LiteralPath (Join-Path $repo 'f.txt') -Value 'x'
            git -C $repo add f.txt 2>$null
            git -C $repo commit -qm 'init' 2>$null
        }

        $planPath = Join-Path $planDir '2026-09-01-do-the-thing.md'
        if (-not $NoPlan)
        {
            Set-Content -LiteralPath $planPath -Value "# Plan: do the thing`n`nStatus: DONE`nBranch: feature/thing`nBase: abc1234`n"
            git -C $plansRepo init -q -b main . 2>$null
            git -C $plansRepo config user.email 'test@example.com' 2>$null
            git -C $plansRepo config user.name 'Test' 2>$null
            git -C $plansRepo config commit.gpgsign false 2>$null
            git -C $plansRepo add -A 2>$null
            git -C $plansRepo commit -qm 'plan' 2>$null
        }

        return [pscustomobject]@{
            Root        = $root
            Repo        = $repo
            Projects    = $projects
            PlansRepo   = $plansRepo
            ArchiveRoot = Join-Path $vault 'plan-archive'
            PlanPath    = $planPath
            EncodedRepo = Get-EncodedName $repo
        }
    }

    function New-Session
    {
        param(
            [Parameter(Mandatory)] $Fixture,
            [Parameter(Mandatory)] [string]$ProjectDirName,
            [Parameter(Mandatory)] [string]$SessionId,
            [string]$Cwd,
            [datetime]$Start = (Get-Date).AddHours(-2),
            [datetime]$End = (Get-Date)
        )

        if (-not $Cwd)
        {
            $Cwd = $Fixture.Repo
        }

        $dir = Join-Path $Fixture.Projects $ProjectDirName
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $file = Join-Path $dir "$SessionId.jsonl"
        $line = [pscustomobject]@{
            type      = 'user'
            cwd       = $Cwd
            timestamp = $Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $file -Value $line
        (Get-Item -LiteralPath $file).LastWriteTime = $End

        return $file
    }

    function Invoke-Archive
    {
        param(
            [Parameter(Mandatory)] $Fixture,
            [switch]$WithPlan,
            [string[]]$ExtraArgs = @()
        )

        $planArgs = if ($WithPlan) { @('-PlanPath', $Fixture.PlanPath) } else { @() }

        $stdout = & pwsh -NoProfile -File $script:ScriptPath `
            -RepoPath $Fixture.Repo `
            -ArchiveRoot $Fixture.ArchiveRoot `
            -ProjectsRoot $Fixture.Projects `
            @planArgs @ExtraArgs 2>$null
        $code = $LASTEXITCODE

        $json = $null
        $jsonLine = @($stdout) | Where-Object { $_ -is [string] -and $_.StartsWith('{') } | Select-Object -Last 1
        if ($jsonLine)
        {
            $json = $jsonLine | ConvertFrom-Json
        }

        return [pscustomobject]@{
            ExitCode = $code
            Result   = $json
        }
    }

    function Get-ZipEntryName
    {
        param([string]$ZipPath)

        $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        try
        {
            return @($zip.Entries | ForEach-Object { $_.FullName })
        }
        finally
        {
            $zip.Dispose()
        }
    }
}

Describe 'Archive-Sessions' {
    Context 'with a plan to reference' {
        BeforeAll {
            $script:fx = New-Fixture -Name 'happy'
            New-Session -Fixture $script:fx -ProjectDirName $script:fx.EncodedRepo -SessionId 'aaaa-1111' | Out-Null
            $script:run = Invoke-Archive -Fixture $script:fx -WithPlan
        }

        It 'exits 0' {
            $script:run.ExitCode | Should -Be 0
        }

        It 'names the folder date - repo - branch with the branch slash flattened' {
            $expected = '{0} - myrepo - feature-thing' -f (Get-Date).ToString('yyyy-MM-dd')
            (Split-Path -Leaf $script:run.Result.archiveFolder) | Should -Be $expected
        }

        It 'leaves the plan in the plans repository, unmodified' {
            Test-Path -LiteralPath $script:fx.PlanPath | Should -BeTrue
            (Get-Content -LiteralPath $script:fx.PlanPath -Raw) | Should -BeLike '*Status: DONE*'
            git -C $script:fx.PlansRepo status --porcelain | Should -BeNullOrEmpty
        }

        It 'copies no plan into the archive folder' {
            @(Get-ChildItem -LiteralPath $script:run.Result.archiveFolder -File | ForEach-Object { $_.Name }) |
                Should -Be @('conversations.zip', 'index.md')
        }

        It 'copies the transcript into conversations.zip under its project folder' {
            $entries = Get-ZipEntryName -ZipPath (Join-Path $script:run.Result.archiveFolder 'conversations.zip')
            $entries | Should -Be @("$($script:fx.EncodedRepo)/aaaa-1111.jsonl")
        }

        It 'leaves the source transcript in place' {
            Test-Path -LiteralPath (Join-Path $script:fx.Projects "$($script:fx.EncodedRepo)/aaaa-1111.jsonl") | Should -BeTrue
        }

        It 'writes an index.md pointing at the plan where it lives' {
            $index = Get-Content -LiteralPath (Join-Path $script:run.Result.archiveFolder 'index.md') -Raw
            $index | Should -BeLike '*# Plan: do the thing*'
            $index | Should -BeLike "*$($script:fx.PlanPath)*"
            $index | Should -BeLike '*not moved; kept in the plans repository*'
            $index | Should -BeLike '*myrepo*'
            $index | Should -BeLike '*feature/thing*'
            $index | Should -BeLike '*Status at archive: DONE*'
            $index | Should -BeLike '*abc1234*'
            $index | Should -BeLike '*aaaa-1111*'
        }

        It 'records the plans repository commit the archive was taken beside' {
            $expected = (git -C $script:fx.PlansRepo rev-parse HEAD).Trim()
            $script:run.Result.planCommit | Should -Be $expected
            (Get-Content -LiteralPath (Join-Path $script:run.Result.archiveFolder 'index.md') -Raw) |
                Should -BeLike "*$expected*"
        }

        It 'reports the metadata as JSON' {
            $script:run.Result.repo | Should -Be 'myrepo'
            $script:run.Result.branch | Should -Be 'feature/thing'
            $script:run.Result.planPath | Should -Be $script:fx.PlanPath
            $script:run.Result.planStatus | Should -Be 'DONE'
            $script:run.Result.planBase | Should -Be 'abc1234'
            $script:run.Result.sessionCount | Should -Be 1
            $script:run.Result.whatIf | Should -BeFalse
        }
    }

    Context 'without a plan' {
        BeforeAll {
            $script:fxNoPlan = New-Fixture -Name 'no-plan-arg'
            New-Session -Fixture $script:fxNoPlan -ProjectDirName $script:fxNoPlan.EncodedRepo -SessionId 'bbbb-2222' | Out-Null
            $script:runNoPlan = Invoke-Archive -Fixture $script:fxNoPlan
        }

        It 'archives the sessions anyway' {
            $script:runNoPlan.ExitCode | Should -Be 0
            $script:runNoPlan.Result.sessionCount | Should -Be 1
        }

        It 'dates the folder today and titles the index from repo and branch' {
            $expected = '{0} - myrepo - feature-thing' -f (Get-Date).ToString('yyyy-MM-dd')
            (Split-Path -Leaf $script:runNoPlan.Result.archiveFolder) | Should -Be $expected
            (Get-Content -LiteralPath (Join-Path $script:runNoPlan.Result.archiveFolder 'index.md') -Raw) |
                Should -BeLike '*# myrepo - feature/thing*'
        }

        It 'reports no plan fields' {
            $script:runNoPlan.Result.planPath | Should -BeNullOrEmpty;
            $script:runNoPlan.Result.planStatus | Should -BeNullOrEmpty;
            $script:runNoPlan.Result.planCreated | Should -BeNullOrEmpty;
        }

        It 'defaults the cutoff to a week back' {
            $cutoff = [datetime]::Parse($script:runNoPlan.Result.cutoff)
            $cutoff | Should -BeGreaterThan (Get-Date).AddDays(-8)
            $cutoff | Should -BeLessThan (Get-Date).AddDays(-6)
        }
    }

    Context 'repository naming' {
        It 'falls back to the work tree directory name when there is no origin remote' {
            $fx = New-Fixture -Name 'no-origin' -Origin ''
            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 0
            $run.Result.repo | Should -Be 'repo'
        }

        It 'uses the short SHA when HEAD is detached' {
            $fx = New-Fixture -Name 'detached'
            $sha = (git -C $fx.Repo rev-parse --short HEAD).Trim()
            git -C $fx.Repo checkout -q --detach 2>$null
            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 0
            $run.Result.branch | Should -Be $sha
        }
    }

    Context 'session selection' {
        It 'keeps sessions active after the cutoff and drops older ones' {
            $fx = New-Fixture -Name 'cutoff'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'recent' -End (Get-Date) | Out-Null
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'ancient' -End (Get-Date).AddDays(-30) | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 0
            @($run.Result.sessions.sessionId) | Should -Be @('recent')
        }

        It 'keeps a session that ended inside the grace window before the plan was created' {
            $fx = New-Fixture -Name 'grace'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'just-before' -End (Get-Date).AddHours(-3) | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan -ExtraArgs @('-GraceHours', '6')
            @($run.Result.sessions.sessionId) | Should -Be @('just-before')
        }

        It 'drops a session that ended before the grace window' {
            $fx = New-Fixture -Name 'grace-tight'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'too-early' -End (Get-Date).AddHours(-3) | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan -ExtraArgs @('-GraceHours', '1')
            $run.Result.sessionCount | Should -Be 0
        }

        It 'takes an explicit -Since over anything derived from the plan' {
            $fx = New-Fixture -Name 'since'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'a-week-ago' -End (Get-Date).AddDays(-7) | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan -ExtraArgs @('-Since', (Get-Date).AddDays(-30).ToString('s'))
            @($run.Result.sessions.sessionId) | Should -Be @('a-week-ago')
        }

        It 'includes a project folder for a subdirectory of the work tree' {
            $fx = New-Fixture -Name 'subdir'
            New-Session -Fixture $fx -ProjectDirName "$($fx.EncodedRepo)-sub" -SessionId 'in-subdir' -Cwd (Join-Path $fx.Repo 'sub') | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan
            @($run.Result.sessions.sessionId) | Should -Be @('in-subdir')
        }

        It 'excludes a sibling work tree whose folder name merely shares the prefix' {
            $fx = New-Fixture -Name 'sibling'
            New-Session -Fixture $fx -ProjectDirName "$($fx.EncodedRepo)-other" -SessionId 'elsewhere' -Cwd '/somewhere/else' | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.Result.sessionCount | Should -Be 0
        }

        It 'writes the index even when no transcripts match' {
            $fx = New-Fixture -Name 'no-sessions'
            $run = Invoke-Archive -Fixture $fx -WithPlan

            $run.ExitCode | Should -Be 0
            $run.Result.sessionCount | Should -Be 0
            Test-Path -LiteralPath (Join-Path $run.Result.archiveFolder 'conversations.zip') | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $run.Result.archiveFolder 'index.md') -Raw) | Should -BeLike '*No session transcripts*'
        }
    }

    Context 'dry run' {
        It 'reports what it would do and changes nothing' {
            $fx = New-Fixture -Name 'whatif'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'aaaa-1111' | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan -ExtraArgs @('-WhatIf')

            $run.ExitCode | Should -Be 0
            $run.Result.whatIf | Should -BeTrue
            $run.Result.sessionCount | Should -Be 1
            Test-Path -LiteralPath $fx.PlanPath | Should -BeTrue
            Test-Path -LiteralPath $fx.ArchiveRoot | Should -BeFalse
        }
    }

    Context 'guards' {
        It 'exits 1 when a plan is named but not found' {
            $fx = New-Fixture -Name 'missing-plan' -NoPlan
            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 1
        }

        It 'exits 2 when the archive root parent does not exist' {
            $fx = New-Fixture -Name 'bad-root'
            $fx.ArchiveRoot = Join-Path $fx.Root 'missing/deeper/plan-archive'
            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 2
        }

        It 'exits 4 when the repository path is not a git work tree' {
            $fx = New-Fixture -Name 'no-git' -NoGit
            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 4
        }

        It 'exits 3 when the destination is already populated, and leaves it alone' {
            $fx = New-Fixture -Name 'collide'
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'aaaa-1111' | Out-Null
            $first = Invoke-Archive -Fixture $fx -WithPlan
            $firstIndex = Get-Content -LiteralPath (Join-Path $first.Result.archiveFolder 'index.md') -Raw

            $run = Invoke-Archive -Fixture $fx -WithPlan
            $run.ExitCode | Should -Be 3
            (Get-Content -LiteralPath (Join-Path $first.Result.archiveFolder 'index.md') -Raw) | Should -Be $firstIndex
        }

        It 'overwrites the destination with -Force' {
            $fx = New-Fixture -Name 'force'
            $first = Invoke-Archive -Fixture $fx -WithPlan
            New-Session -Fixture $fx -ProjectDirName $fx.EncodedRepo -SessionId 'cccc-3333' | Out-Null

            $run = Invoke-Archive -Fixture $fx -WithPlan -ExtraArgs @('-Force')
            $run.ExitCode | Should -Be 0
            $run.Result.archiveFolder | Should -Be $first.Result.archiveFolder
            (Get-Content -LiteralPath (Join-Path $run.Result.archiveFolder 'index.md') -Raw) | Should -BeLike '*cccc-3333*'
        }
    }
}
