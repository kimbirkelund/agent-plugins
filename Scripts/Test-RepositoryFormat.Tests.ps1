BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Test-RepositoryFormat.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $script:Settings = Join-Path $PSScriptRoot '../PSScriptAnalyzerSettings.psd1'

    function Invoke-RepositoryFormat
    {
        param([string]$PathValue = $env:PATH)

        $saved = $env:PATH
        try
        {
            $env:PATH = $PathValue
            $command = "& '$($script:Script)' -RepoRoot '$($script:Repo)'; exit `$LASTEXITCODE"
            $output = & $script:Pwsh -NoProfile -Command $command 2>&1
            $code = $LASTEXITCODE
        }
        finally
        {
            $env:PATH = $saved
        }

        [pscustomobject]@{
            ExitCode = $code
            Output   = ($output -join "`n")
        }
    }

    function Add-TrackedFile
    {
        param([string]$Name, [string]$Content)

        Set-Content (Join-Path $script:Repo $Name) $Content -NoNewline
        git -C $script:Repo add -- $Name
    }
}

Describe 'Test-RepositoryFormat' {
    BeforeEach {
        $script:Repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Repo | Out-Null
        git -C $script:Repo init --quiet
        # Add a diagnostic-only rule the formatter cannot fix, to make a lint finding observable.
        $original = Get-Content $script:Settings -Raw
        $text = $original.Replace('IncludeRules = @(', "IncludeRules = @(`n'PSAvoidUsingCmdletAliases'")
        Add-TrackedFile -Name 'PSScriptAnalyzerSettings.psd1' -Content $text
        # The settings file is itself checked, so store it in its formatted form.
        $null = & (Join-Path $PSScriptRoot 'Format-PowerShell.ps1') -Path (Join-Path $script:Repo 'PSScriptAnalyzerSettings.psd1') -RepoRoot $script:Repo
    }

    It 'exits 0 when every tracked file is clean' {
        Add-TrackedFile -Name 'a.json' -Content "{ `"a`": 1 }`n"
        Add-TrackedFile -Name 'a.ps1' -Content "Get-Date`n"

        $result = Invoke-RepositoryFormat

        $result.Output | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'names and rewrites an unformatted file and exits 1' {
        Add-TrackedFile -Name 'u.json' -Content '{"a":1}'

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'u\.json: not formatted'
        Get-Content (Join-Path $script:Repo 'u.json') -Raw | Should -Be "{ `"a`": 1 }`n"
    }

    It 'exits 1 on a lint finding the formatter cannot fix' {
        Add-TrackedFile -Name 'l.ps1' -Content "gci`n"

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'l\.ps1:1 PSAvoidUsingCmdletAliases'
        $result.Output | Should -Not -Match 'not formatted'
    }

    It 'ignores an untracked file' {
        Set-Content (Join-Path $script:Repo 'untracked.json') '{"a":1}' -NoNewline

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 0
        $result.Output | Should -BeNullOrEmpty
        Get-Content (Join-Path $script:Repo 'untracked.json') -Raw | Should -Be '{"a":1}'
    }

    It 'exits 0 for a clean markdown file' {
        Add-TrackedFile -Name 'a.md' -Content "# A`n"

        $result = Invoke-RepositoryFormat

        $result.Output | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }

    It 'names and rewrites an unformatted markdown file and exits 1' {
        Add-TrackedFile -Name 'u.md' -Content "# U`n* item`n"

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'u\.md: not formatted'
        Get-Content (Join-Path $script:Repo 'u.md') -Raw | Should -Not -Be "# U`n* item`n"
    }

    It 'exits 1 when no tracked file is left to check' {
        git -C $script:Repo rm --cached --force --quiet -- PSScriptAnalyzerSettings.psd1
        Add-TrackedFile -Name 'notes.txt' -Content 'x'

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'no tracked files to check'
    }

    It 'ignores a tracked file that no longer exists' {
        Add-TrackedFile -Name 'gone.json' -Content '{"a":1}'
        Remove-Item (Join-Path $script:Repo 'gone.json')

        $result = Invoke-RepositoryFormat

        $result.ExitCode | Should -Be 0
    }

    It 'exits 1 when a tool is missing from PATH' -Skip:$IsWindows {
        Add-TrackedFile -Name 'a.json' -Content "{ `"a`": 1 }`n"
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bin | Out-Null
        $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $shim = Join-Path $bin 'git'
        Set-Content $shim "#!/bin/sh`nexec '$git' `"`$@`""
        chmod +x $shim

        $result = Invoke-RepositoryFormat -PathValue $bin

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'prettier not found on PATH'
    }
}
