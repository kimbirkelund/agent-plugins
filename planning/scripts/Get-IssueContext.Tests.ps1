BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-IssueContext.ps1';
    $script:RealGit = (Get-Command git).Source;

    # One git config for the whole file, so no repository needs its own identity or
    # commit.gpgsign setting and the developer's ~/.gitconfig is never read.
    $script:SavedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL;
    $gitConfig = Join-Path $TestDrive 'gitconfig';
    Set-Content -LiteralPath $gitConfig -Value "[user]`n`tname = Test User`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n";
    $env:GIT_CONFIG_GLOBAL = $gitConfig;

    # The committed repository without a remote, built once and copied per test; never
    # handed to a test.
    $script:RepoTemplate = Join-Path $TestDrive 'template';
    New-Item -ItemType Directory -Path $script:RepoTemplate | Out-Null;
    'code' | Set-Content -LiteralPath (Join-Path $script:RepoTemplate 'file.txt');
    git -C $script:RepoTemplate init --quiet --initial-branch=main;
    git -C $script:RepoTemplate add -A;
    git -C $script:RepoTemplate commit --quiet -m 'initial';

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

        New-Item -ItemType Directory -Path $codeRoot -Force | Out-Null;
        New-Item -ItemType Directory -Path $configHome -Force | Out-Null;

        if ($NoGit)
        {
            New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null;
            'code' | Set-Content -LiteralPath (Join-Path $repoRoot 'file.txt');
        }
        else
        {
            # A fresh copy of the template. The origin URL is not a fixture path, so it is
            # added to the copy rather than built into a template per URL.
            Copy-Item -LiteralPath $script:RepoTemplate -Destination $repoRoot -Recurse;
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

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal;
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

    Context 'host part matching' {

        It 'detects github from git@github-work:org/repo.git' {
            $f = New-Fixture -OriginUrl 'git@github-work:org/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'github';
        }

        It 'detects gitlab from ssh://git@gitlab-work/group/repo.git' {
            $f = New-Fixture -OriginUrl 'ssh://git@gitlab-work/group/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'detects gitlab from https://gitlab.company.com:8443/group/repo.git' {
            $f = New-Fixture -OriginUrl 'https://gitlab.company.com:8443/group/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'detects github from github-work:org/repo.git' {
            $f = New-Fixture -OriginUrl 'github-work:org/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'github';
        }

        It 'detects github from git@GitHub-Work:org/repo.git' {
            $f = New-Fixture -OriginUrl 'git@GitHub-Work:org/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'github';
        }

        It 'detects gitlab from git@gitlab.com:team/github-tools.git' {
            $f = New-Fixture -OriginUrl 'git@gitlab.com:team/github-tools.git';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for git@git.example.com:org/github-x.git and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'git@git.example.com:org/github-x.git';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for git@github-gitlab-mirror:org/repo.git and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'git@github-gitlab-mirror:org/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for /srv/git/github/repo.git and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl '/srv/git/github/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for https://git.example.com/github/repo.git and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'https://git.example.com/github/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for file:///srv/github/repo.git and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'file:///srv/github/repo.git';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for C:\github\repo and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'C:\github\repo';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
        }

        It 'gives no host match for https://github-gitlab.example.com/x and falls back to config then unknown' {
            $f = New-Fixture -OriginUrl 'https://github-gitlab.example.com/x';
            (Invoke-Context $f).Tracker | Should -Be 'unknown';
            Set-IssueConfig $f '{ "issueTracker": "gitlab" }';
            (Invoke-Context $f).Tracker | Should -Be 'gitlab';
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
