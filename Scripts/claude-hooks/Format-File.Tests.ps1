BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Format-File.ps1'
    $script:Settings = Join-Path $PSScriptRoot '../../PSScriptAnalyzerSettings.psd1'

    function Invoke-FormatFile
    {
        param([string]$Stdin)

        $errFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $stdout = $Stdin | & pwsh -NoProfile -File $script:Script -RepoRoot $script:Repo 2>$errFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
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
        $result.Stdout | Should -BeNullOrEmpty
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
