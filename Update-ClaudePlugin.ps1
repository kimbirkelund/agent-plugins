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

    [switch]$SkipUpdate
)

$PSCmdlet.MyInvocation.BoundParameters.Keys | ForEach-Object { Write-Verbose "$($PSCmdlet.MyInvocation.MyCommand)-$($_): $($PSCmdlet.MyInvocation.BoundParameters[$_])" }

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

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
if (-not $SkipCommit)
{
    $repoRoot = git -C $pluginDir rev-parse --show-toplevel 2>$null;
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot)
    {
        throw "'$pluginDir' is not inside a git work tree, so the bump cannot be committed. Pass -SkipCommit to bump without committing.";
    }

    $repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path;
    $relativeManifestPath = [System.IO.Path]::GetRelativePath($repoRoot, $pluginManifestPath).Replace([System.IO.Path]::DirectorySeparatorChar, '/');
}

if ($PSCmdlet.ShouldProcess($pluginManifestPath, "set version to $newVersion"))
{
    Set-Content -LiteralPath $pluginManifestPath -Value $replaced -NoNewline;
}

$commitSha = $null;
if (-not $SkipCommit)
{
    $commitMessage = "bump $Name plugin to $newVersion";

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

$pushed = $false;
if (-not $SkipCommit -and -not $SkipPush)
{
    if ($PSCmdlet.ShouldProcess($repoRoot, 'git push'))
    {
        # The marketplace clone fetches from the remote, so an unpushed bump ships nothing.
        git -C $repoRoot push | Out-Host;
        if ($LASTEXITCODE -ne 0)
        {
            throw "git push failed with exit code $LASTEXITCODE. The version bump is already committed; push it and re-run with -SkipCommit to finish shipping.";
        }

        $pushed = $true;
    }
}

$updated = $false;
if (-not $SkipUpdate)
{
    $pluginId = "$Name@$Marketplace";

    # The marketplace is a clone of the remote, so it has to fetch the pushed commit before
    # the plugin update can find a new version to copy.
    if ($PSCmdlet.ShouldProcess($Marketplace, 'claude plugin marketplace update'))
    {
        claude plugin marketplace update $Marketplace | Out-Host;
        if ($LASTEXITCODE -ne 0)
        {
            throw "'claude plugin marketplace update $Marketplace' failed with exit code $LASTEXITCODE. The version bump is already committed; re-run once the cause is fixed.";
        }
    }

    if ($PSCmdlet.ShouldProcess($pluginId, 'claude plugin update'))
    {
        # Out-Host, not the success stream: the update's own progress lines belong on screen,
        # but this script's output is the result object.
        claude plugin update $pluginId | Out-Host;
        if ($LASTEXITCODE -ne 0)
        {
            throw "'claude plugin update $pluginId' failed with exit code $LASTEXITCODE. The version bump is already committed; re-run the update once the cause is fixed.";
        }

        $updated = $true;
    }
}

[pscustomobject]@{
    Name         = $Name
    Marketplace  = $Marketplace
    OldVersion   = $currentVersion
    NewVersion   = $newVersion
    ManifestPath = $pluginManifestPath
    Commit       = $commitSha
    Pushed       = $pushed
    Updated      = $updated
}
