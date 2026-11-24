BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-PowerShell.ps1'
    $script:Settings = Join-Path $PSScriptRoot '../PSScriptAnalyzerSettings.psd1'

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

    function Invoke-FormatPowerShell
    {
        param(
            [string[]]$Path,
            [hashtable]$Environment = @{},
            [string]$WorkingDirectory = $script:Repo,
            [string]$Extra = ''
        )

        $cwd = $WorkingDirectory

        $saved = @{}
        foreach ($name in $Environment.Keys)
        {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }

        try
        {
            $quoted = ($Path | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
            $run = Invoke-InProcess -Command "& '$($script:Script)' -Path @($quoted) -RepoRoot '$($script:Repo)' $Extra" -WorkingDirectory $cwd
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

Describe 'Format-PowerShell' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        # The formatter fixes every rule in IncludeRules, so add a diagnostic-only rule
        # the formatter cannot fix to make a lint finding observable.
        $original = Get-Content $script:Settings -Raw
        $text = $original.Replace('IncludeRules = @(', "IncludeRules = @(`n'PSAvoidUsingCmdletAliases'")
        $text | Should -Not -Be $original
        Set-Content (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') $text -NoNewline
    }

    It 'rewrites an unformatted file' {
        $file = Join-Path $script:Repo 'a.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

        $result = Invoke-FormatPowerShell -Path 'a.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
        [IO.File]::ReadAllBytes($file)[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'reports a lint finding and exits 1' {
        Set-Content (Join-Path $script:Repo 'b.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPowerShell -Path 'b.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'b\.ps1:1 PSAvoidUsingCmdletAliases'
    }

    It 'reports a parse error as format failed and exits 1' {
        Set-Content (Join-Path $script:Repo 'd.ps1') 'function f { $x = ' -NoNewline

        $result = Invoke-FormatPowerShell -Path 'd.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'd\.ps1: format failed'
    }

    It 'handles an empty file' {
        $file = Join-Path $script:Repo 'empty.ps1'
        New-Item -ItemType File -Path $file | Out-Null

        $result = Invoke-FormatPowerShell -Path 'empty.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        (Get-Item $file).Length | Should -Be 0
    }

    It 'preserves a UTF-8 BOM and CRLF on rewrite' {
        $file = Join-Path $script:Repo 'bom.ps1'
        $bytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes("if (`$true)`r`n{`r`nGet-Date`r`n}")
        [IO.File]::WriteAllBytes($file, $bytes)

        $result = Invoke-FormatPowerShell -Path 'bom.ps1'

        $result.ExitCode | Should -Be 0
        $after = [IO.File]::ReadAllBytes($file)
        $after[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [Text.Encoding]::UTF8.GetString($after) | Should -Match "`r`n    Get-Date"
    }

    It 'formats an absolute path under a directory with a space' {
        $dir = Join-Path $script:Repo 'my dir'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 's.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

        $result = Invoke-FormatPowerShell -Path $file

        $result.ExitCode | Should -Be 0
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'warns about a missing file and exits 0' {
        $result = Invoke-FormatPowerShell -Path 'nope.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Skipping missing file: nope\.ps1'
    }

    It 'resolves a relative path against the current directory' {
        $sub = Join-Path $script:Repo 'sub'
        New-Item -ItemType Directory -Path $sub | Out-Null
        $file = Join-Path $sub 'c.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline

        $result = Invoke-FormatPowerShell -Path 'c.ps1' -WorkingDirectory $sub

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'accepts an already formatted file under the verbatim repo settings' {
        Copy-Item $script:Settings (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') -Force
        $file = Join-Path $script:Repo 'aligned.ps1'
        Set-Content $file "`$short = 1`n`$longer = @{`n    a      = 1`n    longer = 2`n}`n" -NoNewline

        $result = Invoke-FormatPowerShell -Path 'aligned.ps1'

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
    }

    It 'fails a missing PSScriptAnalyzer with a prefixed message' {
        $empty = Join-Path $TestDrive 'no-modules-strict'
        New-Item -ItemType Directory -Path $empty | Out-Null
        Set-Content (Join-Path $script:Repo 'm.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPowerShell -Path 'm.ps1' -Environment @{ PSModulePath = $empty }

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'not checked: PSScriptAnalyzer module not found'
    }

    It 'fails a missing settings file with a prefixed message' {
        Remove-Item (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1')
        Set-Content (Join-Path $script:Repo 'm.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPowerShell -Path 'm.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'not checked: settings file not found'
    }

    It 'reports only the failing file among several' {
        $good = Join-Path $script:Repo 'good.ps1'
        Set-Content $good "if (`$true)`n{`nGet-Date`n}" -NoNewline
        Set-Content (Join-Path $script:Repo 'bad.ps1') 'gci' -NoNewline

        $result = Invoke-FormatPowerShell -Path 'bad.ps1', 'good.ps1'

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'bad\.ps1:1 PSAvoidUsingCmdletAliases'
        $result.Output | Should -Not -Match 'good\.ps1'
        Get-Content $good -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }
}
