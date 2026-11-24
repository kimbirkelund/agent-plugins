BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-Path.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $script:Settings = Join-Path $PSScriptRoot '../../PSScriptAnalyzerSettings.psd1'

    # Spy scripts standing in for the three format scripts. Each logs one line per call,
    # writes a warning to stderr, and fails with a line on stdout when its name is in SPY_FAIL.
    function New-SpyScripts
    {
        $dir = Join-Path $TestDrive ('spies-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = @'
param([string[]]$Path, [string]$RepoRoot)
$name = Split-Path $PSCommandPath -Leaf
Add-Content $env:SPY_LOG "$name|$RepoRoot|$($Path -join ';')"
Write-Warning "warning from $name"
if ($env:SPY_FAIL -split ',' -contains $name)
{
    "failure from $name"
    exit 1
}

if ($env:SPY_NOT_CHECKED -split ',' -contains $name)
{
    "not checked: tool missing for $name"
    exit 1
}

exit 0
'@
        foreach ($name in 'Format-PowerShell.ps1', 'Format-Prettier.ps1', 'Format-Markdown.ps1')
        {
            Set-Content (Join-Path $dir $name) $body
        }

        $dir
    }

    function Invoke-FormatPath
    {
        param(
            [string[]]$Path,
            [hashtable]$Environment = @{},
            [string]$ScriptRoot
        )

        $saved = @{}
        foreach ($name in $Environment.Keys)
        {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }

        try
        {
            $quoted = ($Path | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
            $extra = $ScriptRoot ? " -ScriptRoot '$ScriptRoot'" : ''
            $command = "& '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)'$extra; exit `$LASTEXITCODE"
            $output = & $script:Pwsh -NoProfile -Command $command 2>$null
            $code = $LASTEXITCODE
        }
        finally
        {
            foreach ($name in $saved.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }

        [pscustomobject]@{
            ExitCode = $code
            Output   = ($output -join "`n")
            Calls    = (Test-Path $script:Log) ? @(Get-Content $script:Log) : @()
        }
    }
}

Describe 'Format-Path' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init -q
        Set-Content (Join-Path $script:Repo '.gitignore') 'ignored.md' -NoNewline
        $script:Spies = New-SpyScripts
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
        $script:Env = @{ SPY_LOG = $script:Log }
    }

    Context 'dispatch' {
        It 'sends each extension to its script as absolute paths with RepoRoot' {
            $names = 'a.ps1', 'b.psm1', 'c.psd1', 'd.json', 'e.jsonc', 'f.yml', 'g.yaml', 'h.md'
            foreach ($name in $names)
            {
                Set-Content (Join-Path $script:Repo $name) 'x' -NoNewline
            }

            $result = Invoke-FormatPath -Path $names -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            $result.Calls.Count | Should -Be 3
            $repo = [IO.Path]::GetFullPath($script:Repo)
            $abs = { param($list) ($list | ForEach-Object { Join-Path $repo $_ }) -join ';' }
            $result.Calls | Should -Contain "Format-PowerShell.ps1|$repo|$(& $abs 'a.ps1', 'b.psm1', 'c.psd1')"
            $result.Calls | Should -Contain "Format-Prettier.ps1|$repo|$(& $abs 'd.json', 'e.jsonc', 'f.yml', 'g.yaml')"
            $result.Calls | Should -Contain "Format-Markdown.ps1|$repo|$(& $abs 'h.md')"
        }

        It 'matches extensions regardless of casing' {
            Set-Content (Join-Path $script:Repo 'UP.PS1') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'UP.PS1' -Environment $script:Env -ScriptRoot $script:Spies

            $result.Calls.Count | Should -Be 1
            $result.Calls[0] | Should -Match '^Format-PowerShell\.ps1\|'
        }

        It 'calls no script for an unknown extension' {
            Set-Content (Join-Path $script:Repo 'data.txt') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'data.txt' -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'calls no script for an empty path list' {
            $result = Invoke-FormatPath -Path @() -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'resolves a relative path against RepoRoot' {
            New-Item -ItemType Directory -Path (Join-Path $script:Repo 'sub') | Out-Null
            Set-Content (Join-Path $script:Repo 'sub/a.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'sub/a.md' -Environment $script:Env -ScriptRoot $script:Spies

            $result.Calls[0] | Should -Be ("Format-Markdown.ps1|$([IO.Path]::GetFullPath($script:Repo))|" + (Join-Path ([IO.Path]::GetFullPath($script:Repo)) 'sub/a.md'))
        }
    }

    Context 'skip rules' {
        It 'skips a path under .git' {
            Set-Content (Join-Path $script:Repo '.git/hook.ps1') 'x' -NoNewline

            $result = Invoke-FormatPath -Path '.git/hook.ps1' -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'skips a missing path silently' {
            $result = Invoke-FormatPath -Path 'nope.ps1' -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'skips a git-ignored file' {
            Set-Content (Join-Path $script:Repo 'ignored.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'ignored.md' -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'skips a path outside the repo' {
            $outside = Join-Path $TestDrive 'outside.ps1'
            Set-Content $outside 'x' -NoNewline

            $result = Invoke-FormatPath -Path $outside -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 0
            $result.Calls | Should -BeNullOrEmpty
        }

        It 'passes only the files that survive the skip rules' {
            Set-Content (Join-Path $script:Repo 'keep.md') 'x' -NoNewline
            Set-Content (Join-Path $script:Repo 'ignored.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'keep.md', 'ignored.md', 'nope.md' -Environment $script:Env -ScriptRoot $script:Spies

            $result.Calls.Count | Should -Be 1
            $result.Calls[0] | Should -Match 'keep\.md$'
            $result.Calls[0] | Should -Not -Match 'ignored'
        }
    }

    Context 'aggregation' {
        It 'prints the stdout of a failing script and exits 1 while stderr stays out' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1' -Environment ($script:Env + @{ SPY_FAIL = 'Format-PowerShell.ps1' }) -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Be "Format and lint: fix these in the files you just wrote.`nfailure from Format-PowerShell.ps1"
        }

        It 'prints only the could-not-run group when every line is prefixed' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1' -Environment ($script:Env + @{ SPY_NOT_CHECKED = 'Format-PowerShell.ps1' }) -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Be "Format and lint could not run, so some files were not checked. Tell the user, and ask before installing tools or changing config.`nnot checked: tool missing for Format-PowerShell.ps1"
        }

        It 'prints both groups, fix group first, when findings and not-checked lines mix' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline
            Set-Content (Join-Path $script:Repo 'b.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1', 'b.md' -Environment ($script:Env + @{ SPY_FAIL = 'Format-PowerShell.ps1'; SPY_NOT_CHECKED = 'Format-Markdown.ps1' }) -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Be "Format and lint: fix these in the files you just wrote.`nfailure from Format-PowerShell.ps1`nFormat and lint could not run, so some files were not checked. Tell the user, and ask before installing tools or changing config.`nnot checked: tool missing for Format-Markdown.ps1"
        }

        It 'does not report a script that exits 0 alongside a failing one' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline
            Set-Content (Join-Path $script:Repo 'b.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1', 'b.md' -Environment ($script:Env + @{ SPY_FAIL = 'Format-Markdown.ps1' }) -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Be "Format and lint: fix these in the files you just wrote.`nfailure from Format-Markdown.ps1"
            $result.Calls.Count | Should -Be 2
        }

        It 'collects failures from every group' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline
            Set-Content (Join-Path $script:Repo 'b.json') 'x' -NoNewline
            Set-Content (Join-Path $script:Repo 'c.md') 'x' -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1', 'b.json', 'c.md' -Environment ($script:Env + @{ SPY_FAIL = 'Format-PowerShell.ps1,Format-Prettier.ps1,Format-Markdown.ps1' }) -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'failure from Format-PowerShell\.ps1'
            $result.Output | Should -Match 'failure from Format-Prettier\.ps1'
            $result.Output | Should -Match 'failure from Format-Markdown\.ps1'
        }

        It 'reports a script that throws and exits 1' {
            Set-Content (Join-Path $script:Repo 'a.ps1') 'x' -NoNewline
            Set-Content (Join-Path $script:Spies 'Format-PowerShell.ps1') 'throw "boom"'

            $result = Invoke-FormatPath -Path 'a.ps1' -Environment $script:Env -ScriptRoot $script:Spies

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Be "Format and lint could not run, so some files were not checked. Tell the user, and ask before installing tools or changing config.`nnot checked: Format-PowerShell.ps1 failed: boom"
        }
    }

    Context 'real scripts' {
        It 'formats a ps1 file through Format-PowerShell.ps1' {
            Copy-Item $script:Settings (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1')
            $file = Join-Path $script:Repo 'a.ps1'
            Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

            $result = Invoke-FormatPath -Path 'a.ps1' -Environment $script:Env

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
        }

        It 'reports a parse error from Format-PowerShell.ps1' {
            Copy-Item $script:Settings (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1')
            Set-Content (Join-Path $script:Repo 'd.ps1') 'function f { $x = ' -NoNewline

            $result = Invoke-FormatPath -Path 'd.ps1' -Environment $script:Env

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'd\.ps1: format failed'
        }
    }
}
