BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Update-ClaudePlugin.ps1';

    # Identity and signing for every git call in this file, from one config file instead
    # of per-repository config.
    $script:SavedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL;
    $script:GitConfigFile = Join-Path $TestDrive 'gitconfig';
    "[user]`n`tname = Test User`n`temail = test@example.com`n[commit]`n`tgpgsign = false`n" | Set-Content -LiteralPath $script:GitConfigFile -NoNewline;
    $env:GIT_CONFIG_GLOBAL = $script:GitConfigFile;

    # Builds the git state of a fixture (work tree and bare remote) under $Base. Only the
    # parameters that shape the repository matter; the shims are made per test.
    function Build-Repo
    {
        param(
            [string]$Base,
            [string]$PluginName = 'planning',
            [string]$Version = '0.1.0',
            [string]$MarketplaceName = 'agent-plugins',
            [switch]$NoMarketplaceManifest,
            [switch]$NoGit,
            [switch]$NoRemote,
            [string]$Branch,
            [switch]$Upstream,
            [switch]$Detach
        )

        $root = Join-Path $Base 'repo';
        # The marketplace manifest sits at the repository root, which is where a git-source
        # marketplace looks for it.
        $marketplaceRoot = $root;
        $pluginDir = Join-Path $marketplaceRoot $PluginName;

        New-Item -ItemType Directory -Path (Join-Path $marketplaceRoot '.claude-plugin') -Force | Out-Null;
        New-Item -ItemType Directory -Path (Join-Path $pluginDir '.claude-plugin') -Force | Out-Null;
        New-Item -ItemType Directory -Path (Join-Path $pluginDir 'skills/demo') -Force | Out-Null;

        if (-not $NoMarketplaceManifest)
        {
            @"
{
  "name": "$MarketplaceName",
  "owner": { "name": "test" },
  "plugins": [{ "name": "$PluginName", "source": "./$PluginName" }]
}
"@ | Set-Content -LiteralPath (Join-Path $marketplaceRoot '.claude-plugin/marketplace.json');
        }

        # Deliberately quirky spacing and field order: the script must leave both untouched.
        @"
{
  "name": "$PluginName",
  "version": "$Version",
  "description": "fixture",
  "keywords": ["planning"]
}
"@ | Set-Content -LiteralPath (Join-Path $pluginDir '.claude-plugin/plugin.json');

        '# demo' | Set-Content -LiteralPath (Join-Path $pluginDir 'skills/demo/SKILL.md');
        'fixture' | Set-Content -LiteralPath (Join-Path $root 'README.md');

        if (-not $NoGit)
        {
            git -C $root init --quiet --initial-branch=main;
            git -C $root add -A;
            git -C $root commit --quiet -m 'fixture';

            if (-not $NoRemote)
            {
                $remote = Join-Path $base 'remote.git';
                git init --quiet --bare --initial-branch=main $remote;
                git -C $root remote add origin $remote;
                git -C $root push --quiet -u origin main;
            }
        }

        if (-not $NoGit)
        {
            if ($Branch)
            {
                git -C $root switch --quiet -c $Branch;
                if ($Upstream -and -not $NoRemote)
                {
                    # The upstream has a different name from the local branch, so a bare
                    # `git push` is told apart from `git push -u origin <branch>`.
                    git -C $root config push.default upstream;
                    git -C $root push --quiet -u origin "${Branch}:feature/y";
                }
            }

            if ($Detach) { git -C $root checkout --quiet --detach; }
        }
    }

    function Get-TemplateKey([hashtable]$Parameters)
    {
        # Defaults are filled in so an explicit default and an omitted one share a key.
        $all = @{ PluginName = 'planning'; Version = '0.1.0'; MarketplaceName = 'agent-plugins' };
        foreach ($name in $Parameters.Keys) { $all[$name] = $Parameters[$name]; }
        $parts = foreach ($name in ($all.Keys | Sort-Object)) { "$name=$($all[$name])" }
        return ($parts -join ';');
    }

    # One template per parameter set the tests use, built once and only ever copied.
    $script:Templates = @{};
    $templateSets = @(
        @{},
        @{ Version = '0.2.0' },
        @{ Version = '1.4.7' },
        @{ Version = '0.1.4' },
        @{ Version = 'v1-beta' },
        @{ NoMarketplaceManifest = $true },
        @{ NoGit = $true },
        @{ NoRemote = $true },
        @{ Detach = $true },
        @{ Branch = 'feature/x' },
        @{ Branch = 'feature/x'; Upstream = $true }
    );
    foreach ($set in $templateSets)
    {
        $dir = Join-Path $TestDrive "template-$($script:Templates.Count)";
        New-Item -ItemType Directory -Path $dir | Out-Null;
        Build-Repo -Base $dir @set;
        $script:Templates[(Get-TemplateKey $set)] = $dir;
    }

    # One self-contained fixture per test: a copy of a git work tree whose root is the
    # marketplace, pushed to a bare local remote so the push step has somewhere to go,
    # plus a fake `claude` on PATH that logs its arguments.
    function New-Fixture
    {
        param(
            [string]$PluginName = 'planning',
            [string]$Version = '0.1.0',
            [string]$MarketplaceName = 'agent-plugins',
            [switch]$NoMarketplaceManifest,
            [switch]$NoGit,
            [switch]$NoRemote,
            [int]$ClaudeExitCode = 0,
            [switch]$NoGh,
            [string]$Branch,
            [switch]$Upstream,
            [switch]$Detach
        )

        # The fake claude and its log live outside the work tree, so they never show up
        # as untracked files in the assertions about repository cleanliness.
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $root = Join-Path $base 'repo';
        $marketplaceRoot = $root;
        $pluginDir = Join-Path $marketplaceRoot $PluginName;

        $repoParameters = @{};
        foreach ($entry in $PSBoundParameters.GetEnumerator())
        {
            if ($entry.Key -notin 'ClaudeExitCode', 'NoGh') { $repoParameters[$entry.Key] = $entry.Value; }
        }
        $key = Get-TemplateKey $repoParameters;
        if ($script:Templates.ContainsKey($key))
        {
            New-Item -ItemType Directory -Path $base | Out-Null;
            Copy-Item -LiteralPath (Join-Path $script:Templates[$key] 'repo') -Destination $root -Recurse;
            if (-not $NoGit -and -not $NoRemote)
            {
                Copy-Item -LiteralPath (Join-Path $script:Templates[$key] 'remote.git') -Destination (Join-Path $base 'remote.git') -Recurse;
                git -C $root remote set-url origin (Join-Path $base 'remote.git');
            }
        }
        else
        {
            New-Item -ItemType Directory -Path $base | Out-Null;
            Build-Repo -Base $base @repoParameters;
        }


        $binDir = Join-Path $base 'bin';
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null;
        $claudeLog = Join-Path $base 'claude-args.txt';

        if ($IsWindows)
        {
            @"
@echo off
echo %* >> "$claudeLog"
exit /b $ClaudeExitCode
"@ | Set-Content -LiteralPath (Join-Path $binDir 'claude.cmd');
        }
        else
        {
            $shim = Join-Path $binDir 'claude';
            "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$claudeLog'`nexit $ClaudeExitCode`n" | Set-Content -LiteralPath $shim -NoNewline;
            chmod +x $shim;
        }

        # The gh stub logs its arguments. `pr create` prints a pull request URL; `pr view` serves
        # the next numbered roll-up from gh-responses (the last one repeats); `pr merge` moves
        # main in the bare remote to the ship branch's commit, as a merge would.
        $ghLog = Join-Path $base 'gh-args.txt';
        $ghResponses = Join-Path $base 'gh-responses';
        New-Item -ItemType Directory -Path $ghResponses -Force | Out-Null;
        Set-Content -LiteralPath (Join-Path $ghResponses 'view-1.json') -Value '{"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"ci-success","status":"COMPLETED","conclusion":"SUCCESS"}]}';
        if (-not $NoGh)
        {
            $shim = Join-Path $binDir 'gh';
            $remotePath = Join-Path $base 'remote.git';
            $body = @'
#!/bin/sh
printf '%s\n' "$*" >> 'LOG'
case "$1 $2" in
"pr create")
    echo 'https://example.test/pull/1'
    ;;
"pr view")
    countFile='RESP/count'
    n=$(( $(cat "$countFile" 2>/dev/null || echo 0) + 1 ))
    echo $n > "$countFile"
    f="RESP/view-$n.json"
    [ -f "$f" ] || f=$(ls RESP/view-*.json | sort | tail -1)
    cat "$f"
    ;;
"pr merge")
    b=$(git -C 'REMOTE' for-each-ref --format='%(refname:short)' 'refs/heads/ship/*' | head -1)
    if [ -f 'RESP/merge-diverge' ]; then
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
        git -C 'REMOTE' update-ref refs/heads/main "$(git -C 'REMOTE' commit-tree -m unrelated "$(git -C 'REMOTE' rev-parse 'refs/heads/main^{tree}')")"
    elif [ ! -f 'RESP/merge-noop' ]; then
        git -C 'REMOTE' update-ref refs/heads/main "$(git -C 'REMOTE' rev-parse "refs/heads/$b")"
    fi
    exit $(cat 'RESP/merge-exit' 2>/dev/null || echo 0)
    ;;
esac
exit 0
'@
            $body.Replace('LOG', $ghLog).Replace('RESP', $ghResponses).Replace('REMOTE', $remotePath) | Set-Content -LiteralPath $shim -NoNewline;
            chmod +x $shim;
        }

        $script:SavedPath = $env:PATH;
        if ($NoGh)
        {
            # A PATH holding only the claude shim and a git wrapper, so no real gh is found.
            $gitBin = Join-Path $base 'gitbin';
            New-Item -ItemType Directory -Path $gitBin -Force | Out-Null;
            $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source;
            "#!/bin/sh`nexec '$realGit' `"`$@`"`n" | Set-Content -LiteralPath (Join-Path $gitBin 'git') -NoNewline;
            chmod +x (Join-Path $gitBin 'git');
            $env:PATH = "$binDir$([System.IO.Path]::PathSeparator)$gitBin";
        }
        else
        {
            $env:PATH = "$binDir$([System.IO.Path]::PathSeparator)$env:PATH";
        }

        return [pscustomobject]@{
            Root            = $root
            Remote          = Join-Path $base 'remote.git'
            MarketplaceRoot = $marketplaceRoot
            PluginDir       = $pluginDir
            ManifestPath    = Join-Path $pluginDir '.claude-plugin/plugin.json'
            ClaudeLog       = $claudeLog
            GhLog           = $ghLog
            GhResponses     = $ghResponses
        }
    }

    function Get-ManifestVersion([string]$Path)
    {
        return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json).version;
    }

    function Get-ClaudeCalls([string]$LogPath)
    {
        if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
        return @(Get-Content -LiteralPath $LogPath | Where-Object { $_.Trim() });
    }

    function Get-RemoteHead([string]$Remote, [string]$Branch = 'main')
    {
        return (git -C $Remote rev-parse $Branch);
    }

    # Replaces the roll-ups the gh stub serves to successive `pr view` calls.
    function Set-GhViews($Fixture, [string[]]$Json)
    {
        Remove-Item -Path (Join-Path $Fixture.GhResponses 'view-*.json');
        for ($i = 0; $i -lt $Json.Count; $i++)
        {
            Set-Content -LiteralPath (Join-Path $Fixture.GhResponses "view-$($i + 1).json") -Value $Json[$i];
        }
    }

    function Get-GhCalls([string]$LogPath)
    {
        if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
        return @(Get-Content -LiteralPath $LogPath | Where-Object { $_.Trim() });
    }

    function Test-RemoteBranch([string]$Remote, [string]$Branch)
    {
        git -C $Remote rev-parse --verify --quiet "refs/heads/$Branch" | Out-Null;
        return $LASTEXITCODE -eq 0;
    }

    function Get-HeadFiles([string]$Root)
    {
        return @(git -C $Root show --pretty=format: --name-only HEAD | Where-Object { $_.Trim() });
    }
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:SavedGitConfigGlobal;
}

Describe 'Update-ClaudePlugin' {

    AfterEach {
        if ($script:SavedPath) { $env:PATH = $script:SavedPath; $script:SavedPath = $null; }
    }

    Context 'version arithmetic' {

        It 'patch-bumps by default' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            $result.OldVersion | Should -Be '0.1.0';
            $result.NewVersion | Should -Be '0.1.1';
            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.1';
        }

        It 'bumps the minor part and zeroes the patch' {
            $f = New-Fixture -Version '0.1.4';
            & $script:ScriptPath -Name planning -Version Minor -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.2.0';
        }

        It 'bumps the major part and zeroes the rest' {
            $f = New-Fixture -Version '1.4.7';
            & $script:ScriptPath -Name planning -Version Major -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '2.0.0';
        }

        It 'accepts a bump part case-insensitively' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -Version 'minor' -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.2.0';
        }

        It 'takes an explicit version' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -Version '1.2.3' -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '1.2.3';
        }

        It 'changes nothing in the manifest but the version value' {
            $f = New-Fixture -Version '0.1.0';
            $before = Get-Content -Raw -LiteralPath $f.ManifestPath;
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;
            $after = Get-Content -Raw -LiteralPath $f.ManifestPath;

            $after | Should -Be ($before -replace '"version": "0.1.0"', '"version": "0.1.1"');
        }
    }

    Context 'guards' {

        It 'throws when the plugin has no manifest, and names the plugins it did find' {
            $f = New-Fixture;
            { & $script:ScriptPath -Name nosuch -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*planning*';
        }

        It 'throws when the marketplace root does not exist' {
            $f = New-Fixture;
            { & $script:ScriptPath -Name planning -MarketplaceRoot (Join-Path $f.Root 'nope') } |
                Should -Throw -ExpectedMessage '*does not exist*';
        }

        It 'throws when there is no marketplace manifest and no -Marketplace' {
            $f = New-Fixture -NoMarketplaceManifest;
            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*No marketplace manifest*';
        }

        It 'falls back to -Marketplace when there is no marketplace manifest' {
            $f = New-Fixture -NoMarketplaceManifest;
            & $script:ScriptPath -Name planning -Marketplace elsewhere -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update elsewhere', 'plugin update planning@elsewhere');
        }

        It 'throws when the current version is not MAJOR.MINOR.PATCH' {
            $f = New-Fixture -Version 'v1-beta';
            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*not a MAJOR.MINOR.PATCH*';
        }

        It 'throws on a version argument that is neither a version nor a bump part' {
            $f = New-Fixture;
            { & $script:ScriptPath -Name planning -Version 'sideways' -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*must be a MAJOR.MINOR.PATCH version*';
        }

        It 'refuses a target version that is not greater than the current one' {
            $f = New-Fixture -Version '0.2.0';
            { & $script:ScriptPath -Name planning -Version '0.1.0' -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*not greater than*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.2.0';
        }

        It 'allows a downgrade with -AllowDowngrade' {
            $f = New-Fixture -Version '0.2.0';
            & $script:ScriptPath -Name planning -Version '0.1.0' -AllowDowngrade -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
        }

        It 'throws when the marketplace is not in a git work tree, unless -SkipCommit' {
            $f = New-Fixture -NoGit;
            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*not inside a git work tree*';

            & $script:ScriptPath -Name planning -SkipCommit -MarketplaceRoot $f.MarketplaceRoot | Out-Null;
            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.1';
        }
    }

    Context 'committing' {

        It 'commits the bump with a message naming plugin and version' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
            $result.Commit | Should -Be (git -C $f.Root rev-parse HEAD);
            git -C $f.Root status --porcelain | Should -BeNullOrEmpty;
        }

        It 'commits only the plugin manifest, leaving other dirty and staged work alone' {
            $f = New-Fixture -Version '0.1.0';
            Set-Content -LiteralPath (Join-Path $f.Root 'README.md') -Value 'dirty';
            Set-Content -LiteralPath (Join-Path $f.PluginDir 'skills/demo/SKILL.md') -Value '# edited';
            git -C $f.Root add -- 'planning/skills/demo/SKILL.md';

            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-HeadFiles $f.Root | Should -Be @('planning/.claude-plugin/plugin.json');

            $status = @(git -C $f.Root status --porcelain);
            $status | Should -Contain ' M README.md';
            $status | Should -Contain 'M  planning/skills/demo/SKILL.md';
        }

        It 'leaves the bump uncommitted with -SkipCommit' {
            $f = New-Fixture -Version '0.1.0';
            $before = git -C $f.Root rev-parse HEAD;

            $result = & $script:ScriptPath -Name planning -SkipCommit -MarketplaceRoot $f.MarketplaceRoot;

            git -C $f.Root rev-parse HEAD | Should -Be $before;
            $result.Commit | Should -BeNullOrEmpty;
            git -C $f.Root status --porcelain | Should -Contain ' M planning/.claude-plugin/plugin.json';
        }
    }

    Context 'pushing' {

        It 'pushes the bump, so the marketplace can fetch it' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            Get-RemoteHead $f.Remote 'ship/planning-0.1.1' | Should -Be (git -C $f.Root rev-parse HEAD);
            $result.Pushed | Should -BeTrue;
        }

        It 'leaves the remote behind with -SkipPush' {
            $f = New-Fixture -Version '0.1.0';
            $before = Get-RemoteHead $f.Remote;

            $result = & $script:ScriptPath -Name planning -SkipPush -MarketplaceRoot $f.MarketplaceRoot;

            Get-RemoteHead $f.Remote | Should -Be $before;
            $result.Pushed | Should -BeFalse;
            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
        }

        It 'pushes nothing with -SkipCommit, there being no commit to push' {
            $f = New-Fixture -Version '0.1.0';
            $before = Get-RemoteHead $f.Remote;

            $result = & $script:ScriptPath -Name planning -SkipCommit -MarketplaceRoot $f.MarketplaceRoot;

            Get-RemoteHead $f.Remote | Should -Be $before;
            $result.Pushed | Should -BeFalse;
        }

        It 'throws when the push fails, keeping the committed bump' {
            $f = New-Fixture -Version '0.1.0';
            $hook = Join-Path $f.Remote 'hooks/pre-receive';
            "#!/bin/sh`nexit 1`n" | Set-Content -LiteralPath $hook -NoNewline;
            chmod +x $hook;

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*git push failed*';

            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }
    }

    Context 'claude plugin update' {

        It 'refreshes the marketplace before updating the plugin under its qualified id' {
            $f = New-Fixture;
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
            $result.Updated | Should -BeTrue;
        }

        It 'skips the update with -SkipUpdate' {
            $f = New-Fixture;
            $result = & $script:ScriptPath -Name planning -SkipUpdate -MarketplaceRoot $f.MarketplaceRoot;

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
            $result.Updated | Should -BeFalse;
        }

        It 'throws when the marketplace refresh fails, keeping the committed bump' {
            $f = New-Fixture -Version '0.1.0' -ClaudeExitCode 7;

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*marketplace update agent-plugins*failed with exit code 7*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.1';
            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
        }
    }

    Context 'dry run' {

        It 'touches nothing with -WhatIf' {
            $f = New-Fixture -Version '0.1.0';
            $before = git -C $f.Root rev-parse HEAD;

            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -WhatIf | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
            git -C $f.Root rev-parse HEAD | Should -Be $before;
            git -C $f.Root status --porcelain | Should -BeNullOrEmpty;
            Get-RemoteHead $f.Remote | Should -Be $before;
            Test-RemoteBranch $f.Remote 'ship/planning-0.1.1' | Should -BeFalse;
            git -C $f.Root branch --list 'ship/*' | Should -BeNullOrEmpty;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
            Get-Content -LiteralPath $f.GhLog -ErrorAction SilentlyContinue | Should -BeNullOrEmpty;
        }
    }

    Context 'on main, pull request mode' {

        It 'reports the mode, the ship branch and the pull request URL' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            $result.Mode | Should -Be 'PullRequest';
            $result.Branch | Should -Be 'ship/planning-0.1.1';
            $result.PullRequestUrl | Should -Be 'https://example.test/pull/1';
        }

        It 'refuses when behind origin/main, before writing anything' {
            $f = New-Fixture -Version '0.1.0';
            $other = Join-Path (Split-Path $f.Root -Parent) 'other';
            git clone --quiet $f.Remote $other;
            git -C $other config user.name 'Other';
            git -C $other config user.email 'other@example.com';
            git -C $other config commit.gpgsign false;
            'more' | Set-Content -LiteralPath (Join-Path $other 'more.txt');
            git -C $other add -A;
            git -C $other commit --quiet -m 'ahead';
            git -C $other push --quiet origin main;

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*not at origin/main*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
            git -C $f.Root branch --list 'ship/*' | Should -BeNullOrEmpty;
        }

        It 'refuses when the ship branch exists locally' {
            $f = New-Fixture -Version '0.1.0';
            git -C $f.Root branch 'ship/planning-0.1.1';

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*already exists locally*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
        }

        It 'refuses when the ship branch exists on the remote' {
            $f = New-Fixture -Version '0.1.0';
            git -C $f.Root push --quiet origin 'main:refs/heads/ship/planning-0.1.1';

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*already exists on origin*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
        }

        It 'refuses when gh is missing, before writing anything' -Skip:$IsWindows {
            $f = New-Fixture -Version '0.1.0' -NoGh;

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*gh*not on PATH*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
        }

        It 'does not need gh with -SkipPush' -Skip:$IsWindows {
            $f = New-Fixture -Version '0.1.0' -NoGh;
            & $script:ScriptPath -Name planning -SkipPush -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
        }

        It 'puts the bump commit on the ship branch of the remote and leaves main alone' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @('{"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}');
            $before = Get-RemoteHead $f.Remote;
            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } | Should -Throw;

            git -C $f.Root branch --show-current | Should -Be 'ship/planning-0.1.1';
            git -C $f.Remote log -1 --pretty=%s 'ship/planning-0.1.1' | Should -Be 'bump planning plugin to 0.1.1';
            git -C $f.Remote rev-parse 'ship/planning-0.1.1~1' | Should -Be $before;
            Get-RemoteHead $f.Remote | Should -Be $before;
            git -C $f.Root rev-parse --abbrev-ref 'ship/planning-0.1.1@{u}' | Should -Be 'origin/ship/planning-0.1.1';
        }

        It 'opens the pull request against main with the commit message as title' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            $calls = @(Get-GhCalls $f.GhLog);
            $calls[0] | Should -BeLike 'pr create --base main --head ship/planning-0.1.1 --title bump planning plugin to 0.1.1 --body *0.1.0*0.1.1*';
        }

        It 'stops after the local commit with -SkipPush' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -SkipPush -MarketplaceRoot $f.MarketplaceRoot;

            git -C $f.Root branch --show-current | Should -Be 'ship/planning-0.1.1';
            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
            Test-RemoteBranch $f.Remote 'ship/planning-0.1.1' | Should -BeFalse;
            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
            $result.PullRequestUrl | Should -BeNullOrEmpty;
        }

        It 'skips the guard with -SkipCommit' -Skip:$IsWindows {
            $f = New-Fixture -Version '0.1.0' -NoRemote -NoGh;
            & $script:ScriptPath -Name planning -SkipCommit -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.1';
            git -C $f.Root branch --show-current | Should -Be 'main';
        }

        It 'changes nothing with -WhatIf' {
            $f = New-Fixture -Version '0.1.0';
            $before = git -C $f.Root rev-parse HEAD;
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -WhatIf | Out-Null;

            git -C $f.Root branch --show-current | Should -Be 'main';
            git -C $f.Root branch --list 'ship/*' | Should -BeNullOrEmpty;
            git -C $f.Root rev-parse HEAD | Should -Be $before;
            Test-RemoteBranch $f.Remote 'ship/planning-0.1.1' | Should -BeFalse;
            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
        }
    }

    Context 'waiting, merging and returning to main' {

        BeforeAll {
            $script:Failed = '{"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"format","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]}';
            $script:Cancelled = '{"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"CANCELLED"}]}';
            $script:Empty = '{"state":"OPEN","statusCheckRollup":[]}';
            $script:Pending = '{"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"test","status":"IN_PROGRESS","conclusion":""}]}';
        }

        It 'merges after the checks passed, then updates from the merged commit' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            @(Get-GhCalls $f.GhLog) | Should -Contain 'pr merge https://example.test/pull/1 --merge --delete-branch';
            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
            $result.Merged | Should -BeTrue;
            $result.Updated | Should -BeTrue;
        }

        It 'merges when the roll-up is empty at first and then passes, polling in between' {
            $f = New-Fixture -Version '0.1.0';
            $passed = Get-Content -Raw -LiteralPath (Join-Path $f.GhResponses 'view-1.json');
            Set-GhViews $f @($script:Empty, $script:Pending, $passed);
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -PollIntervalSeconds 0.05 | Out-Null;

            @(Get-GhCalls $f.GhLog | Where-Object { $_ -like 'pr view *' }).Count | Should -Be 3;
            @(Get-GhCalls $f.GhLog) | Should -Contain 'pr merge https://example.test/pull/1 --merge --delete-branch';
        }

        It 'throws on a failed check, naming it and the pull request, without merging or updating' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @($script:Failed);

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage "*'test'*FAILURE*https://example.test/pull/1*";

            @(Get-GhCalls $f.GhLog | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'names the branch the checkout is on and how to leave it when it throws' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @($script:Failed);

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage "*checkout is still on 'ship/planning-0.1.1'*git switch main*";
            git -C $f.Root branch --show-current | Should -Be 'ship/planning-0.1.1';
        }

        It 'throws on a cancelled check without merging or updating' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @($script:Cancelled);

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage "*'test'*CANCELLED*";

            @(Get-GhCalls $f.GhLog | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'throws on timeout without merging or updating' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @($script:Pending);

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -TimeoutSeconds 1 -PollIntervalSeconds 0.2 } |
                Should -Throw -ExpectedMessage '*Timed out after 1 seconds*https://example.test/pull/1*';

            @(Get-GhCalls $f.GhLog | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'leaves the checkout on main at the merged commit with the ship branch gone' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            git -C $f.Root branch --show-current | Should -Be 'main';
            git -C $f.Root rev-parse HEAD | Should -Be (Get-RemoteHead $f.Remote);
            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
            git -C $f.Root branch --list 'ship/*' | Should -BeNullOrEmpty;
        }

        It 'merges but makes no claude call with -SkipUpdate' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -SkipUpdate -MarketplaceRoot $f.MarketplaceRoot;

            @(Get-GhCalls $f.GhLog) | Should -Contain 'pr merge https://example.test/pull/1 --merge --delete-branch';
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
            $result.Merged | Should -BeTrue;
        }

        It 'treats a failing gh pr merge as merged when the pull request is MERGED' {
            $f = New-Fixture -Version '0.1.0';
            $passed = Get-Content -Raw -LiteralPath (Join-Path $f.GhResponses 'view-1.json');
            Set-GhViews $f @($passed, '{"state":"MERGED","statusCheckRollup":[]}');
            Set-Content -LiteralPath (Join-Path $f.GhResponses 'merge-exit') -Value '1';
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            $result.Merged | Should -BeTrue;
            git -C $f.Root branch --show-current | Should -Be 'main';
            git -C $f.Root branch --list 'ship/*' | Should -BeNullOrEmpty;
            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
        }

        It 'throws and makes no claude call when gh pr merge fails and the pull request is not merged' {
            $f = New-Fixture -Version '0.1.0';
            Set-Content -LiteralPath (Join-Path $f.GhResponses 'merge-exit') -Value '1';
            Set-Content -LiteralPath (Join-Path $f.GhResponses 'merge-noop') -Value '';

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*not merged*by hand*';

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'carries the merged note when a step after the merge throws' {
            $f = New-Fixture -Version '0.1.0';
            Set-Content -LiteralPath (Join-Path $f.GhResponses 'merge-diverge') -Value '';

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*up to date with origin/main failed*pull request is merged; finish with*';

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'throws when the pull request is not open' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @('{"state":"CLOSED","statusCheckRollup":[]}');

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*is CLOSED*';

            @(Get-GhCalls $f.GhLog | Where-Object { $_ -like 'pr merge*' }) | Should -BeNullOrEmpty;
        }

        It 'throws on a failed status context' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @('{"state":"OPEN","statusCheckRollup":[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]}');

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage "*'ci/legacy'*FAILURE*";
        }

        It 'waits on a pending status context and merges once it succeeds' {
            $f = New-Fixture -Version '0.1.0';
            Set-GhViews $f @(
                '{"state":"OPEN","statusCheckRollup":[{"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"}]}',
                '{"state":"OPEN","statusCheckRollup":[{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]}');
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -PollIntervalSeconds 0.05 | Out-Null;

            @(Get-GhCalls $f.GhLog) | Should -Contain 'pr merge https://example.test/pull/1 --merge --delete-branch';
        }

        It 'still updates with -SkipCommit on main, having nothing to merge' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -SkipCommit -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
        }

        It 'lists the merge, switch-back and update steps with -WhatIf without doing them' {
            $f = New-Fixture -Version '0.1.0';
            # The What if lines go to the host, so they are read from a child process's output.
            $all = pwsh -NoProfile -File $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -WhatIf 2>&1 | Out-String;

            $all | Should -BeLike '*gh pr merge*';
            $all | Should -BeLike '*git switch main*';
            $all | Should -BeLike '*claude plugin update*';
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'calls neither gh pr merge nor claude with -WhatIf' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -WhatIf | Out-Null;

            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }
    }

    Context 'update only' {

        It 'runs only the two claude calls, in order, and reports the mode' {
            $f = New-Fixture -Version '0.1.0';
            $result = & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
            $result.Mode | Should -Be 'UpdateOnly';
            $result.Updated | Should -BeTrue;
        }

        It 'leaves the manifest byte-identical and makes no commit or push' {
            $f = New-Fixture -Version '0.1.0';
            $hash = (Get-FileHash -LiteralPath $f.ManifestPath).Hash;
            $head = git -C $f.Root rev-parse HEAD;
            $refs = @(git -C $f.Remote for-each-ref);
            & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            (Get-FileHash -LiteralPath $f.ManifestPath).Hash | Should -Be $hash;
            git -C $f.Root rev-parse HEAD | Should -Be $head;
            @(git -C $f.Remote for-each-ref) | Should -Be $refs;
            git -C $f.Root status --porcelain | Should -BeNullOrEmpty;
        }

        It 'works on a feature branch, staying on it' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
            git -C $f.Root branch --show-current | Should -Be 'feature/x';
        }

        It 'never calls gh and needs neither gh nor a git work tree' -Skip:$IsWindows {
            $f = New-Fixture -Version '0.1.0' -NoGh -NoGit;
            & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-ClaudeCalls $f.ClaudeLog | Should -Be @('plugin marketplace update agent-plugins', 'plugin update planning@agent-plugins');
        }

        It 'never calls gh when it is present' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
        }

        It 'refuses a bump argument' {
            $f = New-Fixture -Version '0.1.0';

            { & $script:ScriptPath -Name planning -Version Minor -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*-UpdateOnly*version argument*';
            { & $script:ScriptPath -Name planning '0.1.0' -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*-UpdateOnly*version argument*';

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'refuses -SkipUpdate' {
            $f = New-Fixture -Version '0.1.0';

            { & $script:ScriptPath -Name planning -UpdateOnly -SkipUpdate -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*-UpdateOnly*-SkipUpdate*';

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'makes no claude call with -WhatIf' {
            $f = New-Fixture -Version '0.1.0';
            & $script:ScriptPath -Name planning -UpdateOnly -MarketplaceRoot $f.MarketplaceRoot -WhatIf | Out-Null;

            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }
    }

    Context 'on a feature branch' {

        It 'commits and pushes the bump to that branch without an upstream' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            $before = Get-RemoteHead $f.Remote;
            $result = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot;

            $result.Mode | Should -Be 'FeatureBranch';
            $result.Branch | Should -Be 'feature/x';
            $result.PullRequestUrl | Should -BeNullOrEmpty;
            Get-RemoteHead $f.Remote 'feature/x' | Should -Be (git -C $f.Root rev-parse HEAD);
            git -C $f.Remote log -1 --pretty=%s 'feature/x' | Should -Be 'bump planning plugin to 0.1.1';
            Get-RemoteHead $f.Remote | Should -Be $before;
            git -C $f.Root rev-parse --abbrev-ref 'feature/x@{u}' | Should -Be 'origin/feature/x';
        }

        It 'commits and pushes the bump to that branch with an upstream' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x' -Upstream;
            $before = Get-RemoteHead $f.Remote;
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-RemoteHead $f.Remote 'feature/y' | Should -Be (git -C $f.Root rev-parse HEAD);
            Test-RemoteBranch $f.Remote 'feature/x' | Should -BeFalse;
            Get-RemoteHead $f.Remote | Should -Be $before;
        }

        It 'never calls gh or claude' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }

        It 'works without gh on PATH' -Skip:$IsWindows {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x' -NoGh;
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot | Out-Null;

            Get-RemoteHead $f.Remote 'feature/x' | Should -Be (git -C $f.Root rev-parse HEAD);
        }

        It 'says how to install once the branch has merged' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            $all = & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot 6>&1;

            ($all | Out-String) | Should -BeLike '*./Update-ClaudePlugin.ps1 planning -UpdateOnly*';
        }

        It 'pushes nothing with -SkipPush, and says the bump needs pushing' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            $all = & $script:ScriptPath -Name planning -SkipPush -MarketplaceRoot $f.MarketplaceRoot 6>&1;

            ($all | Out-String) | Should -BeLike '*committed locally*not pushed*';

            git -C $f.Root log -1 --pretty=%s | Should -Be 'bump planning plugin to 0.1.1';
            Test-RemoteBranch $f.Remote 'feature/x' | Should -BeFalse;
        }

        It 'changes nothing with -WhatIf' {
            $f = New-Fixture -Version '0.1.0' -Branch 'feature/x';
            $before = git -C $f.Root rev-parse HEAD;
            & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot -WhatIf | Out-Null;

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
            git -C $f.Root rev-parse HEAD | Should -Be $before;
            Test-RemoteBranch $f.Remote 'feature/x' | Should -BeFalse;
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
            Test-Path -LiteralPath $f.GhLog | Should -BeFalse;
        }

        It 'throws on a detached HEAD' {
            $f = New-Fixture -Version '0.1.0' -Detach;

            { & $script:ScriptPath -Name planning -MarketplaceRoot $f.MarketplaceRoot } |
                Should -Throw -ExpectedMessage '*detached*';

            Get-ManifestVersion $f.ManifestPath | Should -Be '0.1.0';
        }
    }
}
