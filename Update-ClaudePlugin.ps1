<#
.SYNOPSIS
    Ship a change to a plugin in this marketplace: bump its version, commit and push the
    bump, refresh the marketplace, and pull the new version into the installed snapshot.

.DESCRIPTION
    This marketplace is registered from its git remote, not from this directory, so Claude
    Code installs from a commit that has been pushed rather than from the work tree. That
    is deliberate: a half-finished skill in the work tree is not live in every session, and
    shipping is a gesture rather than a side effect of saving a file.

    It also means four things have to happen in order, and all four are easy to forget:

      1. bump `version` in the plugin's plugin.json — `claude plugin update` compares
         nothing else, so an unbumped change reports "already at the latest version" and
         leaves the installed copy stale, with no error;
      2. commit it, and 3. push it, since the marketplace clone fetches from the remote;
      4. `claude plugin marketplace update` so that clone sees the new commit, and only
         then `claude plugin update`, which copies it into
         ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/.

    Only the plugin's plugin.json is committed. Anything else in the work tree, staged or
    not, is left exactly as it was — so an unfinished change stays unshipped even when the
    bump goes out.

.PARAMETER Name
    Plugin directory name under the marketplace root, e.g. 'planning'.

.PARAMETER Version
    Either an explicit semantic version ('1.2.0') or the part to bump: Major, Minor or
    Patch. Defaults to Patch.

.PARAMETER MarketplaceRoot
    Directory holding .claude-plugin/marketplace.json. Defaults to this script's directory.

.PARAMETER Marketplace
    Marketplace name used to address the plugin as <name>@<marketplace>. Read from
    marketplace.json when omitted.

.PARAMETER AllowDowngrade
    Permit a target version that is not greater than the current one.

.PARAMETER SkipCommit
    Write the new version but leave it uncommitted, and push nothing. The marketplace
    refresh and the update still run, so they will find the previous commit — use it to
    bump without shipping.

.PARAMETER SkipPush
    Commit the bump but leave it unpushed. The marketplace fetches from the remote, so the
    new version reaches the installed copy only once it is pushed.

.PARAMETER SkipUpdate
    Bump, commit and push, but do not refresh the marketplace or call
    `claude plugin update`.

.EXAMPLE
    ./Update-ClaudePlugin.ps1 planning
    Patch-bumps the planning plugin, commits and pushes the bump, refreshes the
    marketplace, and updates the installed snapshot.

.EXAMPLE
    ./Update-ClaudePlugin.ps1 planning Minor

.EXAMPLE
    ./Update-ClaudePlugin.ps1 planning 1.0.0 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ArgumentCompleter({
            param ($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)
            $root = $FakeBoundParameters['MarketplaceRoot'];
            if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path $CommandAst.CommandElements[0].Value -Parent; }
            if ([string]::IsNullOrWhiteSpace($root)) { return; }
            Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName '.claude-plugin/plugin.json') } |
                Where-Object { $_.Name -like "$WordToComplete*" } |
                ForEach-Object { $_.Name }
        })]
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Name,

    [Parameter(Position = 1)]
    [ArgumentCompleter({ 'Major', 'Minor', 'Patch' })]
    [string]$Version = 'Patch',

    [string]$MarketplaceRoot = $PSScriptRoot,

    [string]$Marketplace,

    [switch]$AllowDowngrade,

    [switch]$SkipCommit,

    [switch]$SkipPush,

    [switch]$SkipUpdate,

    [switch]$UpdateOnly,

    # How long to wait for the pull request's checks before giving up.
    [int]$TimeoutSeconds = 900,

    # Seconds between polls of the pull request's checks; a parameter only so tests can shorten it.
    [Parameter(DontShow)]
    [double]$PollIntervalSeconds = 10
)

$PSCmdlet.MyInvocation.BoundParameters.Keys | ForEach-Object { Write-Verbose "$($PSCmdlet.MyInvocation.MyCommand)-$($_): $($PSCmdlet.MyInvocation.BoundParameters[$_])" }

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

if ($UpdateOnly -and $PSBoundParameters.ContainsKey('Version'))
{
    throw '-UpdateOnly installs what is already on main and bumps nothing, so it cannot be combined with a version argument.';
}

if ($UpdateOnly -and $SkipUpdate)
{
    throw '-UpdateOnly only runs the update, so it cannot be combined with -SkipUpdate.';
}

$semVerPattern = '^\d+\.\d+\.\d+$';

function Get-BumpedVersion([string]$Current, [string]$Part)
{
    $parts = $Current.Split('.') | ForEach-Object { [int]$_ };
    switch ($Part)
    {
        'Major' { return "$($parts[0] + 1).0.0"; }
        'Minor' { return "$($parts[0]).$($parts[1] + 1).0"; }
        'Patch' { return "$($parts[0]).$($parts[1]).$($parts[2] + 1)"; }
    }
}

if (-not (Test-Path -LiteralPath $MarketplaceRoot -PathType Container))
{
    throw "Marketplace root '$MarketplaceRoot' does not exist.";
}

$marketplaceRootFull = (Resolve-Path -LiteralPath $MarketplaceRoot).Path;
$marketplaceManifestPath = Join-Path $marketplaceRootFull '.claude-plugin/marketplace.json';

if (-not $Marketplace)
{
    if (-not (Test-Path -LiteralPath $marketplaceManifestPath -PathType Leaf))
    {
        throw "No marketplace manifest at '$marketplaceManifestPath'. Pass -Marketplace to name the marketplace explicitly.";
    }

    $Marketplace = (Get-Content -Raw -LiteralPath $marketplaceManifestPath | ConvertFrom-Json).name;
    if (-not $Marketplace)
    {
        throw "Marketplace manifest '$marketplaceManifestPath' has no 'name'.";
    }
}

$pluginDir = Join-Path $marketplaceRootFull $Name;
$pluginManifestPath = Join-Path $pluginDir '.claude-plugin/plugin.json';

if (-not (Test-Path -LiteralPath $pluginManifestPath -PathType Leaf))
{
    $known = Get-ChildItem -Path $marketplaceRootFull -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.claude-plugin/plugin.json') } |
        ForEach-Object { $_.Name };
    $knownText = if ($known) { $known -join ', ' } else { 'none' };
    throw "No plugin manifest at '$pluginManifestPath'. Plugins under '$marketplaceRootFull': $knownText.";
}

$currentVersion = $null;
$newVersion = $null;
$mode = if ($UpdateOnly) { 'UpdateOnly' } else { $null };
$branch = $null;
$shipBranch = $null;
$pullRequestUrl = $null;
$commitSha = $null;
$pushed = $false;
$merged = $false;

# -UpdateOnly installs what is already on main: no bump, no manifest write, no git, no gh.
if (-not $UpdateOnly)
{
    $manifestRaw = Get-Content -Raw -LiteralPath $pluginManifestPath;
    $manifest = $manifestRaw | ConvertFrom-Json;

    if (-not $manifest.PSObject.Properties.Name.Contains('version'))
    {
        throw "Plugin manifest '$pluginManifestPath' has no 'version' field to bump.";
    }

    $currentVersion = [string]$manifest.version;
    if ($currentVersion -notmatch $semVerPattern)
    {
        throw "Current version '$currentVersion' in '$pluginManifestPath' is not a MAJOR.MINOR.PATCH version. Fix it by hand, then bump.";
    }

    if ($Version -match $semVerPattern)
    {
        $newVersion = $Version;
    }
    elseif ($Version -in @('Major', 'Minor', 'Patch'))
    {
        $newVersion = Get-BumpedVersion -Current $currentVersion -Part $Version;
    }
    else
    {
        throw "-Version must be a MAJOR.MINOR.PATCH version or one of Major, Minor, Patch. Got '$Version'.";
    }

    if (-not $AllowDowngrade -and ([version]$newVersion -le [version]$currentVersion))
    {
        throw "Target version $newVersion is not greater than the current $currentVersion, so 'claude plugin update' would treat it as no change. Pass -AllowDowngrade if that is really what you want.";
    }

    Write-Verbose "$Name@$Marketplace : $currentVersion -> $newVersion";

    # Replace the version value in place rather than round-tripping the JSON, so field order,
    # indentation and the prettier-canonical formatting all survive the bump.
    $versionValuePattern = '(?<lead>"version"\s*:\s*")' + [regex]::Escape($currentVersion) + '(?<trail>")';
    $replaced = [regex]::Replace($manifestRaw, $versionValuePattern, "`${lead}$newVersion`${trail}", 1);
    if ($replaced -eq $manifestRaw)
    {
        throw "Could not locate the version value '$currentVersion' in '$pluginManifestPath'.";
    }

    $repoRoot = $null;
    $relativeManifestPath = $null;
    $mode = $null;
    $branch = $null;
    $shipBranch = $null;
    $pullRequestUrl = $null;

    $repoRoot = git -C $pluginDir rev-parse --show-toplevel 2>$null;
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot)
    {
        $repoRoot = $null;
        if (-not $SkipCommit)
        {
            throw "'$pluginDir' is not inside a git work tree, so the bump cannot be committed. Pass -SkipCommit to bump without committing.";
        }
    }
    else
    {
        $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path;
        $relativeManifestPath = [System.IO.Path]::GetRelativePath($repoRoot, $pluginManifestPath).Replace([System.IO.Path]::DirectorySeparatorChar, '/');

        # The checked-out branch picks the mode: on main the bump ships through its own pull
        # request; on any other branch it rides that branch.
        $branch = git -C $repoRoot symbolic-ref --quiet --short HEAD 2>$null;
        if ($LASTEXITCODE -ne 0 -or -not $branch)
        {
            throw "HEAD is detached in '$repoRoot'. Check out a branch before shipping.";
        }

        $mode = if ($branch -eq 'main') { 'PullRequest' } else { 'FeatureBranch' };
    }

    if ($mode -eq 'PullRequest' -and -not $SkipCommit)
    {
        $shipBranch = "ship/$Name-$newVersion";

        if (-not $SkipPush -and -not (Get-Command gh -ErrorAction SilentlyContinue))
        {
            throw "'gh' is not on PATH, so the pull request cannot be opened. Install it, or pass -SkipPush to stop after the local commit.";
        }

        # Fetch is read-only, so it runs under -WhatIf too.
        git -C $repoRoot fetch --quiet origin;
        if ($LASTEXITCODE -ne 0)
        {
            throw "git fetch origin failed with exit code $LASTEXITCODE. Nothing was changed.";
        }

        $headSha = git -C $repoRoot rev-parse HEAD;
        $originSha = git -C $repoRoot rev-parse --verify --quiet refs/remotes/origin/main;
        if ($LASTEXITCODE -ne 0 -or $headSha -ne $originSha)
        {
            throw "main ($headSha) is not at origin/main ($originSha). Bring main up to date with origin/main before shipping.";
        }

        git -C $repoRoot show-ref --verify --quiet "refs/heads/$shipBranch";
        if ($LASTEXITCODE -eq 0)
        {
            throw "Branch '$shipBranch' already exists locally. Delete it or pick another version.";
        }

        git -C $repoRoot ls-remote --exit-code origin "refs/heads/$shipBranch" | Out-Null;
        if ($LASTEXITCODE -eq 0)
        {
            throw "Branch '$shipBranch' already exists on origin. Delete it or pick another version.";
        }
    }

    if ($PSCmdlet.ShouldProcess($pluginManifestPath, "set version to $newVersion"))
    {
        Set-Content -LiteralPath $pluginManifestPath -Value $replaced -NoNewline;
    }

    $commitSha = $null;
    $pushed = $false;
    $merged = $false;
    $onShipBranch = $false;

    try
    {
        if (-not $SkipCommit)
        {
            $commitMessage = "bump $Name plugin to $newVersion";

            if ($mode -eq 'PullRequest' -and $PSCmdlet.ShouldProcess($repoRoot, "create branch $shipBranch"))
            {
                git -C $repoRoot switch --quiet -c $shipBranch;
                if ($LASTEXITCODE -ne 0)
                {
                    throw "git switch -c $shipBranch failed.";
                }

                $onShipBranch = $true;
            }

            if ($PSCmdlet.ShouldProcess($relativeManifestPath, "commit `"$commitMessage`""))
            {
                # Stage and commit this one path only; a pathspec commit ignores whatever else is
                # in the index, so unrelated staged work is neither committed nor disturbed.
                git -C $repoRoot add -- $relativeManifestPath;
                if ($LASTEXITCODE -ne 0)
                {
                    throw "git add failed for '$relativeManifestPath'.";
                }

                git -C $repoRoot commit --quiet -m $commitMessage -- $relativeManifestPath;
                if ($LASTEXITCODE -ne 0)
                {
                    throw "git commit failed for '$relativeManifestPath'.";
                }

                $commitSha = git -C $repoRoot rev-parse HEAD;
            }
        }

        if (-not $SkipCommit -and -not $SkipPush)
        {
            $pushBranch = if ($mode -eq 'PullRequest') { $shipBranch } else { $branch };

            if ($PSCmdlet.ShouldProcess($repoRoot, "git push $pushBranch"))
            {
                git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null | Out-Null;
                $hasUpstream = $LASTEXITCODE -eq 0;

                if ($mode -eq 'FeatureBranch' -and $hasUpstream)
                {
                    git -C $repoRoot push | Out-Host;
                }
                else
                {
                    git -C $repoRoot push -u origin $pushBranch | Out-Host;
                }

                if ($LASTEXITCODE -ne 0)
                {
                    throw "git push failed with exit code $LASTEXITCODE. The bump is committed on '$pushBranch'; push it with 'git push -u origin $pushBranch' once the cause is fixed.";
                }

                $pushed = $true;
            }

            if ($mode -eq 'PullRequest' -and $pushed -and $PSCmdlet.ShouldProcess($shipBranch, 'gh pr create'))
            {
                Push-Location $repoRoot;
                try
                {
                    $created = gh pr create --base main --head $shipBranch --title $commitMessage --body "Bump the $Name plugin from $currentVersion to $newVersion.";
                    $createExit = $LASTEXITCODE;
                }
                finally
                {
                    Pop-Location;
                }

                if ($createExit -ne 0)
                {
                    throw "gh pr create failed with exit code $createExit. Branch '$shipBranch' is pushed; open the pull request by hand.";
                }

                $pullRequestUrl = @($created)[-1];
            }
        }

        if ($mode -eq 'PullRequest' -and -not $SkipCommit -and -not $SkipPush)
        {
            if ($pullRequestUrl)
            {
                # Wait for every check to pass. No checks reported yet means keep waiting, not pass.
                $failedStates = @('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE');
                $clock = [System.Diagnostics.Stopwatch]::StartNew();
                while ($true)
                {
                    $viewLines = gh pr view $pullRequestUrl --json 'statusCheckRollup,state';
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw "gh pr view failed with exit code $LASTEXITCODE while waiting for the checks of $pullRequestUrl.";
                    }

                    $view = ($viewLines -join "`n") | ConvertFrom-Json;
                    if ("$($view.state)" -ne 'OPEN')
                    {
                        throw "The pull request $pullRequestUrl is $($view.state), not open, so it was not merged.";
                    }

                    $checks = @($view.statusCheckRollup | Where-Object { $_ });
                    $pending = $false;
                    foreach ($check in $checks)
                    {
                        if ($check.__typename -eq 'StatusContext')
                        {
                            $checkName = $check.context;
                            $verdict = "$($check.state)".ToUpperInvariant();
                            $isPending = $verdict -in 'PENDING', 'EXPECTED';
                        }
                        else
                        {
                            $checkName = $check.name;
                            $verdict = "$($check.conclusion)".ToUpperInvariant();
                            $isPending = "$($check.status)".ToUpperInvariant() -ne 'COMPLETED';
                        }

                        if ($isPending)
                        {
                            $pending = $true;
                        }
                        elseif ($verdict -in $failedStates)
                        {
                            throw "Check '$checkName' did not pass ($verdict) on $pullRequestUrl, so it was not merged.";
                        }
                    }

                    if ($checks.Count -gt 0 -and -not $pending)
                    {
                        break;
                    }

                    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds)
                    {
                        throw "Timed out after $TimeoutSeconds seconds waiting for the checks of $pullRequestUrl, so it was not merged.";
                    }

                    Start-Sleep -Milliseconds ([int]($PollIntervalSeconds * 1000));
                }
            }

            if ($PSCmdlet.ShouldProcess($shipBranch, 'gh pr merge'))
            {
                Push-Location $repoRoot;
                try
                {
                    gh pr merge $pullRequestUrl --merge --delete-branch | Out-Host;
                    $mergeExit = $LASTEXITCODE;
                }
                finally
                {
                    Pop-Location;
                }

                if ($mergeExit -eq 0)
                {
                    $merged = $true;
                }
                else
                {
                    # With the ship branch checked out, gh also does local work after the remote
                    # merge and can fail there; the pull request's own state is the truth.
                    $stateLines = gh pr view $pullRequestUrl --json state;
                    $stateExit = $LASTEXITCODE;
                    if ($stateExit -eq 0 -and (($stateLines -join "`n") | ConvertFrom-Json).state -eq 'MERGED')
                    {
                        $merged = $true;
                    }
                    else
                    {
                        throw "gh pr merge failed with exit code $mergeExit and the pull request is not merged. The checks passed; merge $pullRequestUrl by hand.";
                    }
                }
            }

            # Under -WhatIf nothing merged, but the steps that would follow are still listed.
            if ($merged -or $WhatIfPreference)
            {
                if ($PSCmdlet.ShouldProcess($repoRoot, 'git switch main'))
                {
                    git -C $repoRoot switch --quiet main;
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw 'git switch main failed after the merge.';
                    }

                    $onShipBranch = $false;
                }

                if ($PSCmdlet.ShouldProcess($repoRoot, 'bring main up to date with origin/main'))
                {
                    # fetch plus merge rather than `git pull`, which refuses to run with staged changes.
                    git -C $repoRoot fetch --quiet origin;
                    if ($LASTEXITCODE -eq 0)
                    {
                        git -C $repoRoot merge --quiet --ff-only refs/remotes/origin/main;
                    }

                    if ($LASTEXITCODE -ne 0)
                    {
                        throw 'Bringing main up to date with origin/main failed after the merge.';
                    }
                }

                # gh may already have removed the local branch together with the remote one.
                git -C $repoRoot show-ref --verify --quiet "refs/heads/$shipBranch";
                if (($LASTEXITCODE -eq 0 -or $WhatIfPreference) -and $PSCmdlet.ShouldProcess($shipBranch, 'delete the local ship branch'))
                {
                    git -C $repoRoot branch --quiet -d $shipBranch;
                    if ($LASTEXITCODE -ne 0)
                    {
                        throw "Could not delete the merged local branch '$shipBranch'; delete it by hand.";
                    }
                }
            }
        }
    }
    catch
    {
        $notes = @();
        if ($onShipBranch)
        {
            $notes += "The checkout is still on '$shipBranch'; 'git switch main' returns to main.";
        }

        if ($pullRequestUrl)
        {
            $notes += "The pull request is $pullRequestUrl.";
        }

        if ($merged)
        {
            $notes += 'The pull request is merged; finish with git switch main, git pull --ff-only (stash staged changes first), then claude plugin marketplace update and claude plugin update by hand.';
        }

        if ($notes)
        {
            throw "$($_.Exception.Message) $($notes -join ' ')";
        }

        throw;
    }

    if ($mode -eq 'FeatureBranch' -and -not $SkipCommit)
    {
        if ($pushed)
        {
            Write-Host "The bump is on '$branch', not on main. Once that branch has merged, install it with: ./Update-ClaudePlugin.ps1 $Name -UpdateOnly";
        }
        elseif ($commitSha)
        {
            Write-Host "The bump is committed locally on '$branch' but not pushed. Push it, and once that branch has merged, install it with: ./Update-ClaudePlugin.ps1 $Name -UpdateOnly";
        }
        else
        {
            Write-Host '-WhatIf: nothing was changed.';
        }
    }

}

$updated = $false;
# On main the installed copy updates only from the merged commit, or from what -SkipCommit left
# in place; under -WhatIf the calls are listed.
$wouldMerge = $WhatIfPreference -and $mode -eq 'PullRequest' -and -not $SkipCommit -and -not $SkipPush;
if (-not $SkipUpdate -and $mode -ne 'FeatureBranch' -and ($UpdateOnly -or $merged -or $SkipCommit -or $wouldMerge))
{
    $pluginId = "$Name@$Marketplace";

    # The marketplace is a clone of the remote, so it has to fetch the merged commit before
    # the plugin update can find a new version to copy.
    if ($PSCmdlet.ShouldProcess($Marketplace, 'claude plugin marketplace update'))
    {
        claude plugin marketplace update $Marketplace | Out-Host;
        if ($LASTEXITCODE -ne 0)
        {
            throw "'claude plugin marketplace update $Marketplace' failed with exit code $LASTEXITCODE. The bump is merged on main; run that command by hand, then 'claude plugin update $pluginId'.";
        }
    }

    if ($PSCmdlet.ShouldProcess($pluginId, 'claude plugin update'))
    {
        # Out-Host, not the success stream: the update's own progress lines belong on screen,
        # but this script's output is the result object.
        claude plugin update $pluginId | Out-Host;
        if ($LASTEXITCODE -ne 0)
        {
            throw "'claude plugin update $pluginId' failed with exit code $LASTEXITCODE. The bump is merged on main; run that command by hand once the cause is fixed.";
        }

        $updated = $true;
    }
}

[pscustomobject]@{
    Name           = $Name
    Mode           = $mode
    Branch         = if ($mode -eq 'PullRequest') { $shipBranch } else { $branch }
    PullRequestUrl = $pullRequestUrl
    Marketplace    = $Marketplace
    OldVersion     = $currentVersion
    NewVersion     = $newVersion
    ManifestPath   = $pluginManifestPath
    Commit         = $commitSha
    Pushed         = $pushed
    Merged         = $merged
    Updated        = $updated
}
