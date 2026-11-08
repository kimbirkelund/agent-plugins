BeforeDiscovery {
    $script:HasPrettier = [bool](Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-Path.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $script:Settings = Join-Path $PSScriptRoot '../../PSScriptAnalyzerSettings.psd1'

    function Invoke-FormatPath
    {
        param(
            [string[]]$Path,
            [hashtable]$Environment = @{}
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
            $prefix = $Environment.ContainsKey('PSModulePath') ? "`$env:PSModulePath = '$($Environment['PSModulePath'])'; " : ''
            $command = "$prefix& '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)'; exit `$LASTEXITCODE"
            $output = & $script:Pwsh -NoProfile -Command $command 2>&1
        }
        finally
        {
            foreach ($name in $saved.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }

        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output -join "`n")
        }
    }
}

Describe 'Format-Path' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init -q
        # The formatter fixes every rule in IncludeRules, so add a diagnostic-only rule
        # the formatter cannot fix to make a lint finding observable.
        $text = (Get-Content $script:Settings -Raw).Replace('IncludeRules = @(', "IncludeRules = @(`n'PSAvoidUsingCmdletAliases'")
        Set-Content (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') $text -NoNewline
        Set-Content (Join-Path $script:Repo '.gitignore') 'ignored.md' -NoNewline
    }

    It 'rewrites an unformatted ps1 file' {
        $file = Join-Path $script:Repo 'a.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

        $result = Invoke-FormatPath -Path 'a.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'reports a lint finding and exits 1' {
        Set-Content (Join-Path $script:Repo 'b.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPath -Path 'b.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'b\.ps1:1 PSAvoidUsingCmdletAliases'
    }

    It 'reports a parse error and exits 1' {
        Set-Content (Join-Path $script:Repo 'd.ps1') 'function f { $x = ' -NoNewline

        $result = Invoke-FormatPath -Path 'd.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'd\.ps1: format failed'
    }

    It 'handles an empty ps1 file' {
        $file = Join-Path $script:Repo 'empty.ps1'
        New-Item -ItemType File -Path $file | Out-Null

        $result = Invoke-FormatPath -Path 'empty.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        (Get-Item $file).Length | Should -Be 0
    }

    It 'preserves a UTF-8 BOM and CRLF on rewrite' {
        $file = Join-Path $script:Repo 'bom.ps1'
        $bytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes("if (`$true)`r`n{`r`nGet-Date`r`n}")
        [IO.File]::WriteAllBytes($file, $bytes)

        $result = Invoke-FormatPath -Path 'bom.ps1'

        $result.ExitCode | Should -Be 0
        $after = [IO.File]::ReadAllBytes($file)
        $after[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($after) | Should -Match 'Get-Date'
        [Text.Encoding]::UTF8.GetString($after) | Should -Match "`r`n    Get-Date"
    }

    It 'formats an absolute path under a directory with a space' {
        $dir = Join-Path $script:Repo 'my dir'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 's.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

        $result = Invoke-FormatPath -Path $file

        $result.ExitCode | Should -Be 0
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'skips a path under .git' {
        $file = Join-Path $script:Repo '.git/hook.ps1'
        Set-Content $file 'gci' -NoNewline

        $result = Invoke-FormatPath -Path '.git/hook.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'skips a missing path silently' {
        $result = Invoke-FormatPath -Path 'nope.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'treats a missing prettier as success' {
        $bin = Join-Path $TestDrive 'bin-only-git'
        New-Item -ItemType Directory -Path $bin | Out-Null
        New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'git') -Target (Get-Command git -CommandType Application).Source | Out-Null
        $file = Join-Path $script:Repo 'p.md'
        Set-Content $file "# Title`n* item`n" -NoNewline

        $result = Invoke-FormatPath -Path 'p.md' -Environment @{ PATH = $bin }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "# Title`n* item`n"
    }

    It 'treats a missing PSScriptAnalyzer as success' {
        $empty = Join-Path $TestDrive 'no-modules'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $file = Join-Path $script:Repo 'm.ps1'
        Set-Content $file 'gci' -NoNewline

        $result = Invoke-FormatPath -Path 'm.ps1' -Environment @{ PSModulePath = $empty }

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'reports only the failing file among several' {
        $good = Join-Path $script:Repo 'good.ps1'
        Set-Content $good "if (`$true)`n{`nGet-Date`n}" -NoNewline
        Set-Content (Join-Path $script:Repo 'bad.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPath -Path 'bad.ps1', 'good.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'bad\.ps1:1 PSAvoidUsingCmdletAliases'
        $result.Output | Should -Not -Match 'good\.ps1'
        Get-Content $good -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'rewrites an unformatted md file with prettier' -Skip:(-not $script:HasPrettier) {
        $file = Join-Path $script:Repo 'c.md'
        Set-Content $file "# Title`n* item`n" -NoNewline

        $result = Invoke-FormatPath -Path $file

        $result.ExitCode | Should -Be 0
        Get-Content $file -Raw | Should -Be "# Title`n`n- item`n"
    }

    It 'leaves a git-ignored file untouched' {
        $file = Join-Path $script:Repo 'ignored.md'
        Set-Content $file "# Title`n* item`n" -NoNewline

        $result = Invoke-FormatPath -Path 'ignored.md'

        $result.ExitCode | Should -Be 0
        Get-Content $file -Raw | Should -Be "# Title`n* item`n"
    }

    It 'leaves a path outside the repo untouched' {
        $outside = Join-Path $TestDrive 'outside.ps1'
        Set-Content $outside 'function  f{ $x = "a" }' -NoNewline

        $result = Invoke-FormatPath -Path $outside

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $outside -Raw | Should -Be 'function  f{ $x = "a" }'
    }

    It 'ignores an unknown extension silently' {
        $file = Join-Path $script:Repo 'data.txt'
        Set-Content $file "a  `n*  b" -NoNewline

        $result = Invoke-FormatPath -Path 'data.txt'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "a  `n*  b"
    }
}
