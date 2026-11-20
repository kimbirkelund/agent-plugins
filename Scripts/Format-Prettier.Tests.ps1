BeforeAll {
    if (-not (Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue))
    {
        throw 'prettier is required for these tests but was not found on PATH. Install it (npm install -g prettier).'
    }

    $script:Script = Join-Path $PSScriptRoot 'Format-Prettier.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    function Invoke-FormatPrettier
    {
        param(
            [string[]]$Path,
            [hashtable]$Environment = @{},
            [string]$WorkingDirectory = $script:Repo
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
            $command = "Set-Location '$WorkingDirectory'; & '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)'; exit `$LASTEXITCODE"
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

Describe 'Format-Prettier' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
    }

    It 'rewrites an unformatted json file' {
        $file = Join-Path $script:Repo 'a.json'
        Set-Content $file '{"a":1,"b":[1,2]}' -NoNewline

        $result = Invoke-FormatPrettier -Path 'a.json'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "{ `"a`": 1, `"b`": [1, 2] }`n"
    }

    It 'rewrites an unformatted yml file' {
        $file = Join-Path $script:Repo 'a.yml'
        Set-Content $file "a:   1`nb:    [1,2]`n" -NoNewline

        $result = Invoke-FormatPrettier -Path 'a.yml'

        $result.ExitCode | Should -Be 0
        Get-Content $file -Raw | Should -Be "a: 1`nb: [1, 2]`n"
    }

    It 'reports invalid json with prettier output and exits 1' {
        Set-Content (Join-Path $script:Repo 'bad.json') '{"a":' -NoNewline

        $result = Invoke-FormatPrettier -Path 'bad.json'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'bad\.json: prettier failed'
        $result.Output | Should -Match 'bad\.json'
    }

    It 'warns about a missing file and exits 0' {
        $result = Invoke-FormatPrettier -Path 'nope.json'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Skipping missing file: nope\.json'
    }

    It 'resolves a relative path against the current directory' {
        $sub = Join-Path $script:Repo 'sub'
        New-Item -ItemType Directory -Path $sub | Out-Null
        $file = Join-Path $sub 'c.json'
        Set-Content $file '{"a":1}' -NoNewline

        $result = Invoke-FormatPrettier -Path 'c.json' -WorkingDirectory $sub

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "{ `"a`": 1 }`n"
    }

    It 'treats a missing prettier as success' {
        $file = Join-Path $script:Repo 'a.json'
        Set-Content $file '{"a":1}' -NoNewline
        $bin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $bin | Out-Null
        $saved = $env:PATH
        $env:PATH = $bin
        try
        {
            $quoted = "'a.json'"
            $command = "Set-Location '$($script:Repo)'; & '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)'; exit `$LASTEXITCODE"
            $output = & $script:Pwsh -NoProfile -Command $command 2>&1
            $code = $LASTEXITCODE
        }
        finally
        {
            $env:PATH = $saved
        }

        $code | Should -Be 0
        $output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be '{"a":1}'
    }
}
