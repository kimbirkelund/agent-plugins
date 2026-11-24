BeforeAll {
    if (-not (Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue))
    {
        throw 'prettier is required for these tests but was not found on PATH. Install it (npm install -g prettier).'
    }

    $script:Script = Join-Path $PSScriptRoot 'Format-Prettier.ps1'

    # Runs a command in this process the way "pwsh -NoProfile -Command ... 2>&1" did: every
    # stream and the console are merged into one text, a terminating error becomes its message
    # and exit code 1, and everything the call can change is restored afterwards.
    function Invoke-InProcess
    {
        param(
            [string]$Command,
            [string]$WorkingDirectory
        )

        $location = Get-Location
        $consoleOut = [Console]::Out
        $consoleError = [Console]::Error
        $consoleIn = [Console]::In
        $encoding = [Console]::OutputEncoding
        $preference = $ErrorActionPreference
        $savedExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
        $stdout = [IO.StringWriter]::new()
        $stderr = [IO.StringWriter]::new()
        $lines = [System.Collections.Generic.List[string]]::new()
        try
        {
            if ($WorkingDirectory)
            {
                Set-Location -LiteralPath $WorkingDirectory
            }

            # A child pwsh ran without the runner's strict mode; this reverts when the function returns.
            Set-StrictMode -Off
            [Console]::SetOut($stdout)
            [Console]::SetError($stderr)
            $global:LASTEXITCODE = 0
            try
            {
                & ([scriptblock]::Create($Command)) *>&1 | ForEach-Object {
                    $item = $_
                    switch ($item)
                    {
                        { $item -is [string] } { $lines.Add($item); break }
                        { $item -is [System.Management.Automation.WarningRecord] } { $lines.Add("WARNING: $($item.Message)"); break }
                        { $item -is [System.Management.Automation.ErrorRecord] } { $lines.Add($item.ToString()); break }
                        { $item -is [System.Management.Automation.InformationRecord] } { $lines.Add($item.ToString()); break }
                        default { $item | Out-String -Stream | ForEach-Object { $lines.Add($_) } }
                    }
                }
                $code = $global:LASTEXITCODE
            }
            catch
            {
                $lines.Add($_.ToString())
                $code = 1
            }
        }
        finally
        {
            [Console]::SetOut($consoleOut)
            [Console]::SetError($consoleError)
            [Console]::SetIn($consoleIn)
            [Console]::OutputEncoding = $encoding
            $ErrorActionPreference = $preference
            if ($savedExitCode)
            {
                $global:LASTEXITCODE = $savedExitCode.Value
            }
            else
            {
                Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
            }
            Set-Location -LiteralPath $location.Path
        }

        foreach ($text in @($stdout.ToString(), $stderr.ToString()))
        {
            if ($text)
            {
                $lines.AddRange([string[]]($text.TrimEnd("`r", "`n") -split '\r?\n'))
            }
        }

        [pscustomobject]@{
            ExitCode = $code
            Output   = ($lines -join "`n")
        }
    }

    function Invoke-FormatPrettier
    {
        param(
            [string[]]$Path,
            [hashtable]$Environment = @{},
            [string]$WorkingDirectory = $script:Repo,
            [string]$Extra = ''
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
            $run = Invoke-InProcess -Command "& '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)' $Extra" -WorkingDirectory $WorkingDirectory
        }
        finally
        {
            foreach ($name in $saved.Keys)
            {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }

        $run
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

    It 'fails a missing prettier with a prefixed message' {
        Set-Content (Join-Path $script:Repo 'a.json') '{"a":1}' -NoNewline
        $bin = Join-Path $TestDrive 'bin-strict'
        New-Item -ItemType Directory -Path $bin | Out-Null
        $saved = $env:PATH
        $env:PATH = $bin
        try
        {
            $run = Invoke-InProcess -Command "& '$($script:Script)' -Path @('a.json') -RepoRoot '$($script:Repo)'" -WorkingDirectory $script:Repo
            $output = $run.Output
            $code = $run.ExitCode
        }
        finally
        {
            $env:PATH = $saved
        }

        $code | Should -Be 1
        ($output -join "`n") | Should -Match 'not checked: prettier not found on PATH'
    }

    It 'still formats with prettier present' {
        $file = Join-Path $script:Repo 'a.json'
        Set-Content $file '{"a":1}' -NoNewline

        $result = Invoke-FormatPrettier -Path 'a.json'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }
}
