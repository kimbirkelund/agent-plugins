BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Update-ClaudePlugin.ps1';

    # One self-contained fixture per test: a git work tree whose root is the marketplace,
    # pushed to a bare local remote so the push step has somewhere to go, plus a fake
    # `claude` on PATH that logs its arguments.
    function New-Fixture
    {
        param(
            [string]$PluginName = 'planning',
            [string]$Version = '0.1.0',
            [string]$MarketplaceName = 'agent-plugins',
            [switch]$NoMarketplaceManifest,
            [switch]$NoGit,
            [switch]$NoRemote,
            [int]$ClaudeExitCode = 0
        )

        # The fake claude and its log live outside the work tree, so they never show up
        # as untracked files in the assertions about repository cleanliness.
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('n').Substring(0, 8));
        $root = Join-Path $base 'repo';
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
            git -C $root config user.name 'Test User';
            git -C $root config user.email 'test@example.com';
            git -C $root config commit.gpgsign false;
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

        $script:SavedPath = $env:PATH;
        $env:PATH = "$binDir$([System.IO.Path]::PathSeparator)$env:PATH";

        return [pscustomobject]@{
            Root            = $root
            Remote          = Join-Path $base 'remote.git'
            MarketplaceRoot = $marketplaceRoot
            PluginDir       = $pluginDir
            ManifestPath    = Join-Path $pluginDir '.claude-plugin/plugin.json'
            ClaudeLog       = $claudeLog
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

    function Get-RemoteHead([string]$Remote)
    {
        return (git -C $Remote rev-parse main);
    }

    function Get-HeadFiles([string]$Root)
    {
        return @(git -C $Root show --pretty=format: --name-only HEAD | Where-Object { $_.Trim() });
    }
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

            Get-RemoteHead $f.Remote | Should -Be (git -C $f.Root rev-parse HEAD);
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
            $f = New-Fixture -Version '0.1.0' -NoRemote;

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
            Get-ClaudeCalls $f.ClaudeLog | Should -BeNullOrEmpty;
        }
    }
}
