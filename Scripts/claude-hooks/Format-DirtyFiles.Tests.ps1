BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-DirtyFiles.ps1'
    $script:Settings = Join-Path $PSScriptRoot '../../PSScriptAnalyzerSettings.psd1'
    $script:Unformatted = "if (`$true)`n{`nGet-Date`n}"
    $script:Formatted = "if (`$true)`n{`n    Get-Date`n}"

    function Invoke-DirtyFiles
    {
        $errFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $stdout = '' | & pwsh -NoProfile -File $script:Script -RepoRoot $script:Repo 2>$errFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Stdout   = ($stdout -join "`n")
            Stderr   = (Get-Content $errFile -Raw)
        }
    }

    function Set-Mtime
    {
        param([string]$File, [datetime]$Time)

        (Get-Item $File).LastWriteTimeUtc = $Time
    }
}

Describe 'Format-DirtyFiles' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init -q
        # The formatter fixes every rule in IncludeRules, so add a diagnostic-only rule
        # the formatter cannot fix to make a lint finding observable.
        $text = (Get-Content $script:Settings -Raw).Replace('IncludeRules = @(', "IncludeRules = @(`n'PSAvoidUsingCmdletAliases'")
        Set-Content (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') $text -NoNewline
        Set-Content (Join-Path $script:Repo '.gitignore') "PSScriptAnalyzerSettings.psd1`n" -NoNewline
        $script:Stamp = Join-Path $script:Repo '.git/claude-format-hook-stamp'
        $script:Probe = Join-Path $script:Repo 'probe.ps1'
    }

    It 'formats a new probe on first run and creates the stamp in the git dir' {
        Set-Content $script:Probe $script:Unformatted -NoNewline

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        Get-Content $script:Probe -Raw | Should -Be $script:Formatted
        $script:Stamp | Should -Exist
    }

    It 'does not rewrite an unchanged probe on a second run' {
        Set-Content $script:Probe $script:Unformatted -NoNewline
        Invoke-DirtyFiles | Out-Null
        $before = (Get-Item $script:Probe).LastWriteTimeUtc

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        (Get-Item $script:Probe).LastWriteTimeUtc | Should -Be $before
    }

    It 'formats a touched probe again' {
        Set-Content $script:Probe $script:Unformatted -NoNewline
        Invoke-DirtyFiles | Out-Null
        Set-Content $script:Probe $script:Unformatted -NoNewline
        Set-Mtime $script:Probe ((Get-Item $script:Stamp).LastWriteTimeUtc.AddSeconds(10))

        Invoke-DirtyFiles | Out-Null

        Get-Content $script:Probe -Raw | Should -Be $script:Formatted
    }

    It 'leaves a dirty file older than the stamp alone' {
        Set-Content $script:Probe $script:Unformatted -NoNewline
        New-Item -ItemType File -Path $script:Stamp | Out-Null
        Set-Mtime $script:Probe ((Get-Item $script:Stamp).LastWriteTimeUtc.AddSeconds(-10))

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        Get-Content $script:Probe -Raw | Should -Be $script:Unformatted
    }

    It 'expands an untracked directory' {
        $dir = Join-Path $script:Repo 'sub'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'inner.ps1') $script:Unformatted -NoNewline

        Invoke-DirtyFiles | Out-Null

        Get-Content (Join-Path $dir 'inner.ps1') -Raw | Should -Be $script:Formatted
    }

    It 'skips a deleted tracked file' {
        Set-Content $script:Probe $script:Formatted -NoNewline
        git -C $script:Repo add probe.ps1
        git -C $script:Repo -c user.name=t -c user.email=t@t commit -q -m init
        Remove-Item $script:Probe

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
    }

    It 'exits 2 with the lint text on stderr' {
        Set-Content $script:Probe 'gci' -NoNewline

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -Match 'probe\.ps1:1 PSAvoidUsingCmdletAliases'
    }

    It 'exits 0 and creates the stamp when there is nothing to format' {
        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        $script:Stamp | Should -Exist
    }

    It 'formats only the new path of a staged rename' {
        Set-Content $script:Probe $script:Formatted -NoNewline
        git -C $script:Repo add probe.ps1
        git -C $script:Repo -c user.name=t -c user.email=t@t commit -q -m init
        git -C $script:Repo mv probe.ps1 moved.ps1
        $moved = Join-Path $script:Repo 'moved.ps1'
        Set-Content $moved $script:Unformatted -NoNewline

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        Get-Content $moved -Raw | Should -Be $script:Formatted
        $script:Probe | Should -Not -Exist
    }

    It 'formats a path with a space' {
        $dir = Join-Path $script:Repo 'my dir'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content (Join-Path $dir 'a b.ps1') $script:Unformatted -NoNewline
        Set-Content (Join-Path $script:Repo 'c d.ps1') $script:Unformatted -NoNewline

        $result = Invoke-DirtyFiles

        $result.ExitCode | Should -Be 0
        Get-Content (Join-Path $dir 'a b.ps1') -Raw | Should -Be $script:Formatted
        Get-Content (Join-Path $script:Repo 'c d.ps1') -Raw | Should -Be $script:Formatted
    }

    It 'puts the stamp in the linked worktree git dir' {
        Set-Content (Join-Path $script:Repo 'seed.txt') 'x' -NoNewline
        git -C $script:Repo add seed.txt
        git -C $script:Repo -c user.name=t -c user.email=t@t commit -q -m init
        $wt = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        git -C $script:Repo worktree add -q $wt -b wt-branch
        Copy-Item (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') $wt
        Set-Content (Join-Path $wt 'wt.ps1') $script:Unformatted -NoNewline
        $mainRepo = $script:Repo
        $script:Repo = $wt

        $result = Invoke-DirtyFiles

        $script:Repo = $mainRepo
        $result.ExitCode | Should -Be 0
        Get-Content (Join-Path $wt 'wt.ps1') -Raw | Should -Be $script:Formatted
        $wtGitDir = (git -C $wt rev-parse --absolute-git-dir)
        $wtGitDir | Should -Not -Be (Join-Path $mainRepo '.git')
        Join-Path $wtGitDir 'claude-format-hook-stamp' | Should -Exist
        $script:Stamp | Should -Not -Exist
    }

    It 'exits 0 silently when RepoRoot is not a git repository' {
        $plain = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $plain | Out-Null
        Set-Content (Join-Path $plain 'x.ps1') $script:Unformatted -NoNewline
        $mainRepo = $script:Repo
        $script:Repo = $plain

        $result = Invoke-DirtyFiles

        $script:Repo = $mainRepo
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
        $result.Stderr | Should -BeNullOrEmpty
        Get-Content (Join-Path $plain 'x.ps1') -Raw | Should -Be $script:Unformatted
    }
}
