BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-IssueContext.ps1';
    $script:RealGit = (Get-Command git).Source;

    function New-Fixture
    {
        param(
            [string]$OriginUrl,
            [switch]$NoOrigin,
            [switch]$NoGit
        )

        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $codeRoot = Join-Path $base 'code';
        $repoRoot = Join-Path $codeRoot 'widget';
        $configHome = Join-Path $base 'config';

        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;
        New-Item -ItemType Directory -Path $configHome -Force | Out-Null;
        'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');

        if (-not $NoGit)
        {
            git -C $repoRoot init --quiet --initial-branch=main;
            git -C $repoRoot config user.name 'Test User';
            git -C $repoRoot config user.email 'test@example.com';
            git -C $repoRoot config commit.gpgsign false;
            git -C $repoRoot add -A;
            git -C $repoRoot commit --quiet -m 'initial';
            if (-not $NoOrigin -and $OriginUrl) { git -C $repoRoot remote add origin $OriginUrl }
        }

        $script:SavedEnv = @{
            XDG_CONFIG_HOME   = $env:XDG_CONFIG_HOME
            CLAUDE_PLANS_REPO = $env:CLAUDE_PLANS_REPO
            __CODE_ROOT       = $env:__CODE_ROOT
            PATH              = $env:PATH
        };
        $env:XDG_CONFIG_HOME = $configHome;
        $env:CLAUDE_PLANS_REPO = $null;
        $env:__CODE_ROOT = $codeRoot;

        return [pscustomobject]@{
            Base       = $base
            CodeRoot   = $codeRoot
            RepoRoot   = $repoRoot
            ConfigHome = $configHome
            ConfigPath = Join-Path $configHome 'claude-planning/config.json'
        }
    }

    function Set-IssueConfig($Fixture, [string]$Json)
    {
        New-Item -ItemType Directory -Path (Split-Path $Fixture.ConfigPath -Parent) -Force | Out-Null;
        $Json | Set-Content -LiteralPath $Fixture.ConfigPath;
    }

    function New-IsolatedBin
    {
        # An isolated PATH holding only a symlink to the real git (so the script can still
        # shell out to it) plus whichever stub commands the caller names, so a test never
        # depends on what is actually installed on the machine that runs it.
        param([string[]]$StubCommands = @())

        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        New-Item -ItemType Directory -Path $bin | Out-Null;
        New-Item -ItemType SymbolicLink -Path (Join-Path $bin 'git') -Target $script:RealGit | Out-Null;

        foreach ($name in $StubCommands)
        {
            $stubPath = Join-Path $bin $name;
            "#!/bin/sh`nexit 0`n" | Set-Content -LiteralPath $stubPath -NoNewline;
            if (-not $IsWindows) { & chmod +x $stubPath }
        }

        return $bin;
    }

    function Invoke-Context($Fixture, [hashtable]$Extra = @{})
    {
        $args = @{ Path = $Fixture.RepoRoot } + $Extra;
        return (& $script:ScriptPath @args | ConvertFrom-Json);
    }
}

Describe 'Get-IssueContext' {

    AfterEach {
        if ($script:SavedEnv)
        {
            $env:XDG_CONFIG_HOME = $script:SavedEnv.XDG_CONFIG_HOME;
            $env:CLAUDE_PLANS_REPO = $script:SavedEnv.CLAUDE_PLANS_REPO;
            $env:__CODE_ROOT = $script:SavedEnv.__CODE_ROOT;
            $env:PATH = $script:SavedEnv.PATH;
            $script:SavedEnv = $null;
        }
    }

    Context 'tracker detection from the remote host' {

        It 'detects github and gh from an ssh origin' {
            $f = New-Fixture -OriginUrl 'git@github.com:group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.Cli | Should -Be 'gh';
            $context.Remote | Should -Be 'git@github.com:group/widget.git';
        }

        It 'detects github and gh from an https origin' {
            $f = New-Fixture -OriginUrl 'https://github.com/group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.Cli | Should -Be 'gh';
            $context.Remote | Should -Be 'https://github.com/group/widget.git';
        }

        It 'detects gitlab and glab from an ssh origin' {
            $f = New-Fixture -OriginUrl 'git@gitlab.com:group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'gitlab';
            $context.Cli | Should -Be 'glab';
            $context.Remote | Should -Be 'git@gitlab.com:group/widget.git';
        }

        It 'detects gitlab and glab from an https origin' {
            $f = New-Fixture -OriginUrl 'https://gitlab.com/group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'gitlab';
            $context.Cli | Should -Be 'glab';
            $context.Remote | Should -Be 'https://gitlab.com/group/widget.git';
        }

        It 'detects github from a github.com subdomain host' {
            $f = New-Fixture -OriginUrl 'git@ssh.github.com:group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.Cli | Should -Be 'gh';
        }

        It 'detects gitlab from a gitlab.com subdomain host' {
            $f = New-Fixture -OriginUrl 'https://ci.gitlab.com/group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'gitlab';
            $context.Cli | Should -Be 'glab';
        }

        It 'detects github and gh from an ssh:// origin' {
            $f = New-Fixture -OriginUrl 'ssh://git@github.com/group/widget.git';
            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.Cli | Should -Be 'gh';
            $context.Remote | Should -Be 'ssh://git@github.com/group/widget.git';
        }
    }

    Context 'self-hosted hosts' {

        It 'falls back to the issueTracker config key for a self-hosted host' {
            $f = New-Fixture -OriginUrl 'git@git.example.com:group/widget.git';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'gitlab';
            $context.Cli | Should -Be 'glab';
            $context.Remote | Should -Be 'git@git.example.com:group/widget.git';
        }

        It 'reports unknown for a self-hosted host with no issueTracker configured' {
            $f = New-Fixture -OriginUrl 'git@git.example.com:group/widget.git';

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'unknown';
            $context.Cli | Should -BeNullOrEmpty;
        }

        It 'ignores an issueTracker value that is neither github nor gitlab' {
            $f = New-Fixture -OriginUrl 'git@git.example.com:group/widget.git';
            Set-IssueConfig $f '{ "issueTracker": "bitbucket" }';

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'unknown';
            $context.Cli | Should -BeNullOrEmpty;
        }

        It 'ignores an issueTracker value that is not a string' {
            $f = New-Fixture -OriginUrl 'git@git.example.com:group/widget.git';
            Set-IssueConfig $f '{ "issueTracker": true }';

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'unknown';
            $context.Cli | Should -BeNullOrEmpty;
        }

        It 'falls back to config for a self-hosted ssh:// origin with a port' {
            $f = New-Fixture -OriginUrl 'ssh://git@git.example.com:2222/group/widget.git';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'gitlab';
            $context.Cli | Should -Be 'glab';
            $context.Remote | Should -Be 'ssh://git@git.example.com:2222/group/widget.git';
        }
    }

    Context 'no remote' {

        It 'reports a null remote and an unknown tracker when origin is not configured' {
            $f = New-Fixture -NoOrigin;

            $context = Invoke-Context $f;

            $context.Remote | Should -BeNullOrEmpty;
            $context.Tracker | Should -Be 'unknown';
            $context.Cli | Should -BeNullOrEmpty;
        }

        It 'still resolves the tracker from config with no remote at all' {
            $f = New-Fixture -NoOrigin;
            Set-IssueConfig $f '{ "issueTracker": "github" }';

            $context = Invoke-Context $f;

            $context.Remote | Should -BeNullOrEmpty;
            $context.Tracker | Should -Be 'github';
            $context.Cli | Should -Be 'gh';
        }
    }

    Context 'CLI availability' {

        It 'reports CliAvailable false when the CLI is not on PATH' {
            $f = New-Fixture -OriginUrl 'git@github.com:group/widget.git';
            $env:PATH = New-IsolatedBin;

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.CliAvailable | Should -BeFalse;
        }

        It 'reports CliAvailable true when the CLI is on PATH' {
            $f = New-Fixture -OriginUrl 'git@github.com:group/widget.git';
            $env:PATH = New-IsolatedBin -StubCommands @('gh');

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'github';
            $context.CliAvailable | Should -BeTrue;
        }

        It 'reports CliAvailable false when the tracker is unknown, with no CLI to check' {
            $f = New-Fixture -NoOrigin;
            $env:PATH = New-IsolatedBin;

            $context = Invoke-Context $f;

            $context.Tracker | Should -Be 'unknown';
            $context.Cli | Should -BeNullOrEmpty;
            $context.CliAvailable | Should -BeFalse;
        }
    }

    Context 'repository identity and passthrough fields' {

        It 'names the repository from the origin remote, like Get-PlanContext does' {
            $f = New-Fixture -OriginUrl 'git@github.com:group/renamed.git';
            $context = Invoke-Context $f;

            $context.RepoName | Should -Be 'renamed';
            $context.RepoRoot | Should -Be (Resolve-Path -LiteralPath $f.RepoRoot).Path;
        }

        It 'reports the config path used' {
            $f = New-Fixture -NoOrigin;
            $context = Invoke-Context $f;

            $context.ConfigPath | Should -Be $f.ConfigPath;
        }

        It 'reads a surface hook the same way Get-PlanContext does' {
            $f = New-Fixture -NoOrigin;
            Set-IssueConfig $f '{ "surface": { "skill": "show-me" } }';

            (Invoke-Context $f).Surface.Skill | Should -Be 'show-me';
        }

        It 'reports an unconfigured surface hook as absent' {
            $f = New-Fixture -NoOrigin;
            Set-IssueConfig $f '{ "issueTracker": "github" }';

            (Invoke-Context $f).Surface | Should -BeNullOrEmpty;
        }

        It 'throws outside a git work tree' {
            $f = New-Fixture -NoGit;
            { & $script:ScriptPath -Path $f.RepoRoot } | Should -Throw -ExpectedMessage '*not inside a git work tree*';
        }
    }
}
