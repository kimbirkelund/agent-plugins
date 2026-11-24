BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-Markdown.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    # Stub tools. Each call appends "name|cwd|arg|arg..." to STUB_LOG. markdownlint-cli2 and npx
    # do nothing with --fix; in check mode they sleep STUB_SLEEP seconds, print STUB_FINDINGS
    # and exit STUB_RC. prettier exits STUB_PRETTIER_RC and prints a line when that is non-zero.
    function New-Stub
    {
        param([string[]]$Name)

        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $body = @'
#!/bin/sh
line="${0##*/}|$PWD"
for a in "$@"; do line="$line|$a"; done
printf '%s\n' "$line" >> "$STUB_LOG"
case "${0##*/}" in
    prettier)
        if [ "${STUB_PRETTIER_RC:-0}" != 0 ]; then echo "prettier stub error"; fi
        exit "${STUB_PRETTIER_RC:-0}"
        ;;
    *)
        for a in "$@"; do [ "$a" = --fix ] && exit 0; done
        [ -n "$STUB_SLEEP" ] && exec /bin/sleep "$STUB_SLEEP"
        [ -n "$STUB_FINDINGS" ] && printf '%s\n' "$STUB_FINDINGS"
        exit "${STUB_RC:-0}"
        ;;
esac
'@
        foreach ($item in $Name)
        {
            $stub = Join-Path $dir $item
            Set-Content $stub $body
            chmod +x $stub
        }

        $dir
    }

    function Invoke-FormatMarkdown
    {
        param(
            [string[]]$Path,
            [string]$PathValue = $env:PATH,
            [hashtable]$Environment = @{},
            [string]$Extra = ''
        )

        $saved = @{ PATH = $env:PATH }
        $Environment['STUB_LOG'] = $script:Log
        foreach ($name in $Environment.Keys)
        {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }

        try
        {
            $env:PATH = $PathValue
            $quoted = ($Path | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
            $command = "Set-Location '$($script:Repo)'; & '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)' $Extra; exit `$LASTEXITCODE"
            $output = & $script:Pwsh -NoProfile -Command $command 2>&1
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

Describe 'Format-Markdown' {
    BeforeEach {
        $script:Repo = [IO.Path]::GetFullPath((Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        $script:Log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
        $script:Stub = New-Stub -Name 'markdownlint-cli2', 'prettier'
        $script:StubPath = $script:Stub + [IO.Path]::PathSeparator + $env:PATH
        Set-Content (Join-Path $script:Repo 'a.md') "# A`n" -NoNewline
    }

    It 'warns about a missing file and exits 0' {
        $result = Invoke-FormatMarkdown -Path 'nope.md' -PathValue $script:StubPath

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Skipping missing file: nope\.md'
        $result.Calls | Should -BeNullOrEmpty
    }

    Context 'pipeline' -Skip:$IsWindows {
        It 'runs prettier, cli2 --fix, prettier, cli2 check in that order' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            $names = $result.Calls | ForEach-Object { ($_ -split '\|')[0] }
            $names | Should -Be @('prettier', 'markdownlint-cli2', 'prettier', 'markdownlint-cli2')
            $result.Calls[1] | Should -Match '\|--fix\|'
            $result.Calls[3] | Should -Not -Match '\|--fix\|'
        }

        It 'runs the linter from RepoRoot with the RepoRoot config and literal file arguments' {
            Set-Content (Join-Path $script:Repo '.markdownlint.jsonc') '{}'
            Set-Content -LiteralPath (Join-Path $script:Repo 'b [1].md') -Value "# B`n" -NoNewline

            $result = Invoke-FormatMarkdown -Path 'a.md', 'b [1].md' -PathValue $script:StubPath

            $check = $result.Calls[-1] -split '\|'
            $check[0] | Should -Be 'markdownlint-cli2'
            $check[1] | Should -Be $script:Repo
            $check[2] | Should -Be '--config'
            $check[3] | Should -Be (Join-Path $script:Repo '.markdownlint.jsonc')
            $check[4..($check.Count - 1)] | Should -Be @(":$(Join-Path $script:Repo 'a.md')", ":$(Join-Path $script:Repo 'b [1].md')")
        }

        It 'does not pass the binary path to markdownlint-cli2 found on PATH' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath

            ($result.Calls[1] -split '\|')[2] | Should -Be '--fix'
            $result.Calls[1] | Should -Not -Match 'markdownlint-cli2\|.*markdownlint-cli2'
        }

        It 'falls back to npx with the pinned version when markdownlint-cli2 is not on PATH' {
            $npx = New-Stub -Name 'npx'

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $npx

            $result.ExitCode | Should -Be 0
            $calls = @($result.Calls | Where-Object { $_ -match '^npx\|' })
            $calls.Count | Should -Be 2
            ($calls[0] -split '\|')[2..4] | Should -Be @('--yes', 'markdownlint-cli2', '--fix')
        }

        It 'rewrites an unformatted file with real prettier' {
            if (-not (Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue))
            {
                throw 'prettier is required for this test but was not found on PATH. Install it (npm install -g prettier).'
            }

            $file = Join-Path $script:Repo 'c.md'
            Set-Content $file "# Title`n* item`n" -NoNewline
            $linter = New-Stub -Name 'markdownlint-cli2'
            $real = (Get-Command prettier -CommandType Application | Select-Object -First 1).Source
            $path = $linter + [IO.Path]::PathSeparator + (Split-Path $real)

            $result = Invoke-FormatMarkdown -Path 'c.md' -PathValue $path

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            Get-Content $file -Raw | Should -Be "# Title`n`n- item`n"
        }
    }

    Context 'findings' -Skip:$IsWindows {
        It 'reports stub findings as path line rule message and exits 1' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = 'a.md:3 error MD001/heading-increment Heading levels should only increment by one level at a time [Expected: h2; Actual: h3]'
                STUB_RC       = '1'
            }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '^a\.md:3 MD001 Heading levels should only increment'
        }

        It 'normalises a finding that carries a column' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = 'a.md:2:5 error MD009/no-trailing-spaces Trailing spaces'
                STUB_RC       = '1'
            }

            $result.Output | Should -Match '^a\.md:2 MD009 Trailing spaces'
        }

        It 'accepts a finding without a severity token' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = 'a.md:4 MD022/blanks-around-headings Headings should be surrounded'
                STUB_RC       = '1'
            }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match '^a\.md:4 MD022 Headings should be surrounded'
        }

        It 'normalises an absolute path in the output to a repo-relative one' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = "$(Join-Path $script:Repo 'a.md'):5 error MD012/no-multiple-blanks Multiple blank lines"
                STUB_RC       = '1'
            }

            $result.Output | Should -Match '^a\.md:5 MD012 Multiple blank lines'
        }

        It 'exits 0 on a clean run' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
        }

        It 'reports unparsable output from a failing markdownlint-cli2' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = 'something unexpected'
                STUB_RC       = '2'
            }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'markdownlint-cli2 failed'
            $result.Output | Should -Match 'something unexpected'
        }

        It 'skips lint silently when npm itself fails' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{
                STUB_FINDINGS = 'npm error code E404'
                STUB_RC       = '1'
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
        }

        It 'fails under Strict when npm itself fails' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Extra '-Strict' -Environment @{
                STUB_FINDINGS = 'npm error code E404'
                STUB_RC       = '1'
            }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'npm or npx failed before markdownlint-cli2 ran'
            $result.Output | Should -Match 'npm error code E404'
        }

        It 'fails under Strict when npm fails only in the fix run' {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $stub = Join-Path $dir 'markdownlint-cli2'
            Set-Content $stub "#!/bin/sh`nfor a in `"`$@`"; do [ `"`$a`" = --fix ] && { echo 'npm error code E404'; exit 1; }; done`nexit 0"
            chmod +x $stub
            $path = $dir + [IO.Path]::PathSeparator + $script:StubPath

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $path -Extra '-Strict'
            $plain = Invoke-FormatMarkdown -Path 'a.md' -PathValue $path

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'npm or npx failed before markdownlint-cli2 ran'
            $plain.ExitCode | Should -Be 0
            $plain.Output | Should -BeNullOrEmpty
        }

        It 'fails under Strict when markdownlint-cli2 cannot start, and skips silently otherwise' {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            $stub = Join-Path $dir 'markdownlint-cli2'
            Set-Content $stub "#!/nonexistent/interpreter`n"
            chmod +x $stub
            $path = $dir + [IO.Path]::PathSeparator + $script:StubPath

            $strict = Invoke-FormatMarkdown -Path 'a.md' -PathValue $path -Extra '-Strict'
            $plain = Invoke-FormatMarkdown -Path 'a.md' -PathValue $path

            $strict.ExitCode | Should -Be 1
            $strict.Output | Should -Match 'markdownlint-cli2 could not start'
            $plain.ExitCode | Should -Be 0
            $plain.Output | Should -BeNullOrEmpty
        }

        It 'fails under Strict with a message when the shared budget runs out' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Extra '-Strict -LintTimeoutSeconds 1' -Environment @{
                STUB_SLEEP = '30'
                STUB_RC    = '1'
            }

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'markdownlint-cli2 timed out after 1 s'
        }

        It 'skips lint silently and kills the process when the shared budget runs out' {
            $started = Get-Date

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Extra '-LintTimeoutSeconds 1' -Environment @{
                STUB_SLEEP = '30'
                STUB_RC    = '1'
            }

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            ((Get-Date) - $started).TotalSeconds | Should -BeLessThan 25
        }
    }

    Context 'prettier failure' -Skip:$IsWindows {
        It 'reports the failure once and skips the remaining passes for the file' {
            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $script:StubPath -Environment @{ STUB_PRETTIER_RC = '2' }

            $result.ExitCode | Should -Be 1
            ([regex]::Matches($result.Output, 'a\.md: prettier failed')).Count | Should -Be 1
            @($result.Calls | Where-Object { $_ -match '^prettier\|' }).Count | Should -Be 1
            @($result.Calls | Where-Object { $_ -match '^markdownlint-cli2\|' }).Count | Should -Be 0
        }
    }

    Context 'tools missing' -Skip:$IsWindows {
        It 'exits 0 with neither prettier nor markdownlint available' {
            $empty = Join-Path $TestDrive 'empty-bin'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $file = Join-Path $script:Repo 'm.md'
            Set-Content $file "# Title`n* item`n" -NoNewline

            $result = Invoke-FormatMarkdown -Path 'm.md' -PathValue $empty

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
            Get-Content $file -Raw | Should -Be "# Title`n* item`n"
        }

        It 'fails under Strict naming both missing tools' {
            $empty = Join-Path $TestDrive 'empty-bin-strict'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $empty -Extra '-Strict'

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'prettier not found on PATH'
            $result.Output | Should -Match 'markdownlint-cli2 not found on PATH and npx not found'
        }

        It 'reports a missing prettier once under Strict for several files' {
            $empty = Join-Path $TestDrive 'empty-bin-many'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            Set-Content (Join-Path $script:Repo 'b.md') "# B`n" -NoNewline

            $result = Invoke-FormatMarkdown -Path 'a.md', 'b.md' -PathValue $empty -Extra '-Strict'

            $result.ExitCode | Should -Be 1
            ([regex]::Matches($result.Output, 'prettier not found on PATH')).Count | Should -Be 1
        }

        It 'fails under Strict when only markdownlint-cli2 and npx are missing' {
            $only = New-Stub -Name 'prettier'

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $only -Extra '-Strict'

            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'markdownlint-cli2 not found on PATH and npx not found'
            $result.Output | Should -Not -Match 'prettier not found'
        }

        It 'exits 0 without Strict when only markdownlint-cli2 and npx are missing' {
            $only = New-Stub -Name 'prettier'

            $result = Invoke-FormatMarkdown -Path 'a.md' -PathValue $only

            $result.ExitCode | Should -Be 0
            $result.Output | Should -BeNullOrEmpty
        }
    }

    It 'reports MD001 from the real markdownlint-cli2' {
        if (-not (Get-Command markdownlint-cli2 -CommandType Application -ErrorAction SilentlyContinue) -and -not (Get-Command npx -CommandType Application -ErrorAction SilentlyContinue))
        {
            throw 'markdownlint-cli2 is required for this test but neither markdownlint-cli2 nor npx was found on PATH. Install one (npm install -g markdownlint-cli2).'
        }

        Set-Content (Join-Path $script:Repo 'r.md') "# A`n`n### B`n" -NoNewline

        $result = Invoke-FormatMarkdown -Path 'r.md'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'r\.md:3 MD001'
    }
}
