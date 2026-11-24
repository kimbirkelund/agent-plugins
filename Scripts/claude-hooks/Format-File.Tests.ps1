BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-File.ps1'
    $script:Settings = Join-Path $PSScriptRoot '../../PSScriptAnalyzerSettings.psd1'

    function Invoke-FormatFile
    {
        param([string]$Stdin)

        # Runs the hook in this process instead of a child pwsh -File: stdin comes from a
        # StringReader, stdout is the pipeline plus [Console]::Out, stderr (the error stream
        # plus [Console]::Error) goes to the file a child's 2> would have written, and
        # everything the call can change is restored afterwards.
        $errFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $savedLocation = Get-Location
        $savedPath = $env:PATH
        $savedOut = [Console]::Out
        $savedError = [Console]::Error
        $savedIn = [Console]::In
        $savedEncoding = [Console]::OutputEncoding
        $savedPreference = $ErrorActionPreference
        $savedExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
        $out = [IO.StringWriter]::new()
        $err = [IO.StringWriter]::new()
        $stdout = [System.Collections.Generic.List[string]]::new()
        try
        {
            [Console]::SetOut($out)
            [Console]::SetError($err)
            [Console]::SetIn([IO.StringReader]::new($Stdin))
            # A child pwsh starts without strict mode; the runner sets it, so turn it off
            # for this function scope only.
            Set-StrictMode -Off
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            try
            {
                # A child pwsh -File wrote errors to stderr and warning, verbose, debug and
                # host lines to stdout, so every stream is merged and sorted the same way.
                & $script:Script -RepoRoot $script:Repo *>&1 | ForEach-Object {
                    switch ($_)
                    {
                        { $_ -is [System.Management.Automation.ErrorRecord] } { $err.WriteLine($_.ToString()); break }
                        { $_ -is [System.Management.Automation.WarningRecord] } { $stdout.Add("WARNING: $($_.Message)"); break }
                        { $_ -is [System.Management.Automation.VerboseRecord] } { $stdout.Add("VERBOSE: $($_.Message)"); break }
                        { $_ -is [System.Management.Automation.DebugRecord] } { $stdout.Add("DEBUG: $($_.Message)"); break }
                        default { $stdout.Add([string]$_) }
                    }
                }
                $code = $global:LASTEXITCODE
            }
            catch
            {
                $err.WriteLine($_.ToString())
                $code = 1
            }
        }
        finally
        {
            [Console]::SetOut($savedOut)
            [Console]::SetError($savedError)
            [Console]::SetIn($savedIn)
            [Console]::OutputEncoding = $savedEncoding
            $ErrorActionPreference = $savedPreference
            if ($savedExitCode)
            {
                $global:LASTEXITCODE = $savedExitCode.Value
            }
            else
            {
                Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
            }
            $env:PATH = $savedPath
            Set-Location $savedLocation
        }

        $text = $out.ToString()
        if ($text)
        {
            $stdout.InsertRange(0, [string[]]($text.TrimEnd("`r", "`n") -split "`r?`n"))
        }

        Set-Content $errFile $err.ToString() -NoNewline
        [pscustomobject]@{
            ExitCode = $code
            Stdout   = ($stdout -join "`n")
            Stderr   = (Get-Content $errFile -Raw)
        }
    }
}

Describe 'Format-File' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init -q
        # The formatter fixes every rule in IncludeRules, so add a diagnostic-only rule
        # the formatter cannot fix to make a lint finding observable.
        $text = (Get-Content $script:Settings -Raw).Replace('IncludeRules = @(', "IncludeRules = @(`n'PSAvoidUsingCmdletAliases'")
        Set-Content (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') $text -NoNewline
    }

    It 'formats the file named in the hook JSON' {
        $file = Join-Path $script:Repo 'a.ps1'
        Set-Content $file "if (`$true)`n{`nGet-Date`n}" -NoNewline
        $json = @{ tool_input = @{ file_path = $file } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be "if (`$true)`n{`n    Get-Date`n}"
    }

    It 'exits 0 silently on empty stdin' {
        $result = Invoke-FormatFile -Stdin ''

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
        $result.Stderr | Should -BeNullOrEmpty
    }

    It 'exits 0 silently on garbage stdin' {
        $result = Invoke-FormatFile -Stdin 'not json {{'

        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
        $result.Stderr | Should -BeNullOrEmpty
    }

    It 'exits 0 when the JSON has no file_path' {
        $result = Invoke-FormatFile -Stdin '{"tool_input":{}}'

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
    }

    It 'exits 2 with the lint text on stderr' {
        $file = Join-Path $script:Repo 'b.ps1'
        Set-Content $file 'gci' -NoNewline
        $json = @{ tool_input = @{ file_path = $file } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -Match 'b\.ps1:1 PSAvoidUsingCmdletAliases'
        $result.Stderr | Should -Match ([regex]::Escape('Format and lint: fix these in the files you just wrote.'))
        $result.Stdout | Should -BeNullOrEmpty
    }

    It 'exits 2 with the could-not-run instruction when a tool is missing from PATH' -Skip:$IsWindows {
        $file = Join-Path $script:Repo 'a.json'
        Set-Content $file '{"a":1}' -NoNewline
        $json = @{ tool_input = @{ file_path = $file } } | ConvertTo-Json
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bin | Out-Null
        foreach ($tool in 'git', 'pwsh')
        {
            $real = (Get-Command $tool -CommandType Application | Select-Object -First 1).Source
            $shim = Join-Path $bin $tool
            Set-Content $shim "#!/bin/sh`nexec '$real' `"`$@`""
            chmod +x $shim
        }

        $saved = $env:PATH
        $env:PATH = $bin
        try
        {
            Get-Command prettier -CommandType Application -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $result = Invoke-FormatFile -Stdin $json
        }
        finally
        {
            $env:PATH = $saved
        }

        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -Match ([regex]::Escape('Format and lint could not run, so some files were not checked. Tell the user, and ask before installing tools or changing config.'))
        $result.Stderr | Should -Match 'not checked: prettier not found on PATH'
    }

    It 'leaves a file_path outside the repo untouched' {
        $outside = Join-Path $TestDrive 'outside.ps1'
        Set-Content $outside "if (`$true)`n{`nGet-Date`n}" -NoNewline
        $json = @{ tool_input = @{ file_path = $outside } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        Get-Content $outside -Raw | Should -Be "if (`$true)`n{`nGet-Date`n}"
    }

    It 'leaves a git-ignored file_path untouched' {
        Set-Content (Join-Path $script:Repo '.gitignore') "skipped.ps1`n" -NoNewline
        $file = Join-Path $script:Repo 'skipped.ps1'
        Set-Content $file 'gci' -NoNewline
        $json = @{ tool_input = @{ file_path = $file } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        Get-Content $file -Raw | Should -Be 'gci'
    }

    It 'does nothing for a deleted file_path' {
        $file = Join-Path $script:Repo 'gone.ps1'
        $json = @{ tool_input = @{ file_path = $file } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 0
        $result.Stderr | Should -BeNullOrEmpty
        $file | Should -Not -Exist
    }

    It 'falls back to notebook_path' {
        $file = Join-Path $script:Repo 'n.ps1'
        Set-Content $file 'gci' -NoNewline
        $json = @{ tool_input = @{ notebook_path = $file } } | ConvertTo-Json

        $result = Invoke-FormatFile -Stdin $json

        $result.ExitCode | Should -Be 2
        $result.Stderr | Should -Match 'n\.ps1:1 PSAvoidUsingCmdletAliases'
    }
}
