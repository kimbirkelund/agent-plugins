<#
.SYNOPSIS
    Resolve everything /ipln needs to know about the issue tracker for the repository in
    the current work tree: which tracker it is, which CLI talks to it, and whether that
    CLI is on PATH.

.DESCRIPTION
    An issue tracker is a property of the repository's origin remote, not of the plan, so
    this is a separate script from Get-PlanContext.ps1 even though the two answer
    neighbouring questions. It calls Get-PlanContext.ps1 as a command — never dot-sourced
    — to resolve the repository root, name and shared config file, so the two scripts
    never disagree about where either of those is.

    Detection order:
      1. the host of the origin remote: github.com (or a *.github.com host such as
         ssh.github.com) selects `github`; gitlab.com selects `gitlab`;
      2. otherwise the `issueTracker` key in the shared planning config, for a self-hosted
         instance whose host name gives nothing away — value `github` or `gitlab`;
      3. otherwise `unknown`, and the caller decides what to do about it.

    Configuration is read from the same file Get-PlanContext.ps1 reads,
    $XDG_CONFIG_HOME/claude-planning/config.json, falling back to
    ~/.config/claude-planning/config.json:

      {
        "issueTracker": "gitlab",
        "surface": { "skill": "show-me" }
      }

    `issueTracker` is the only key this script looks at itself; `surface` is read by
    calling Get-PlanContext.ps1, whose Surface field is passed through unchanged.

.PARAMETER Path
    Work tree to resolve the context for. Defaults to the current directory.

.PARAMETER ConfigPath
    Configuration file to read instead of the default location.

.OUTPUTS
    One JSON object on stdout.

.EXAMPLE
    pwsh -File Get-IssueContext.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = '.',

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

function Get-RemoteHost([string]$Url)
{
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $value = $Url.Trim();

    # scp-like syntax carries no scheme: user@host:path. Matched first because a scheme
    # URL can also embed a user before its own '@', and that form must fall through to the
    # scheme pattern below instead.
    if ($value -match '^[^@/\s]+@([^:/\s]+):')
    {
        return $Matches[1].ToLowerInvariant();
    }

    # scheme://[user@]host[:port]/path
    if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://(?:[^@/\s]+@)?([^:/\s]+)')
    {
        return $Matches[1].ToLowerInvariant();
    }

    return $null;
}

function Get-TrackerFromHost([string]$RemoteHost)
{
    if (-not $RemoteHost) { return $null }
    if ($RemoteHost -match '(^|\.)github\.com$') { return 'github' }
    if ($RemoteHost -match '(^|\.)gitlab\.com$') { return 'gitlab' }

    return $null;
}

function Get-TrackerFromConfig($Config)
{
    if (-not $Config) { return $null }
    if (-not $Config.PSObject.Properties.Name.Contains('issueTracker')) { return $null }

    $value = $Config.issueTracker;
    if ($value -isnot [string]) { return $null }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    switch ($value.Trim().ToLowerInvariant())
    {
        'github' { return 'github' }
        'gitlab' { return 'gitlab' }
        default { return $null }
    }
}

$contextArgs = @{ Path = $Path };
if ($ConfigPath) { $contextArgs['ConfigPath'] = $ConfigPath }

# Get-PlanContext.ps1 already knows the repository's identity and the shared config file;
# asking it rather than re-deriving keeps the two scripts agreeing on both, and its own
# "not inside a git work tree" check covers this script too.
$planContext = & (Join-Path $PSScriptRoot 'Get-PlanContext.ps1') @contextArgs | ConvertFrom-Json;

$repoRoot = $planContext.RepoRoot;

$remote = git -C $repoRoot remote get-url origin 2>$null;
if ($LASTEXITCODE -ne 0 -or -not $remote)
{
    $remote = $null;
}
else
{
    $remote = $remote.Trim();
}

$config = $null;
if ($planContext.ConfigPath -and (Test-Path -LiteralPath $planContext.ConfigPath -PathType Leaf))
{
    $config = Get-Content -Raw -LiteralPath $planContext.ConfigPath | ConvertFrom-Json;
}

$tracker = Get-TrackerFromHost (Get-RemoteHost $remote);
if (-not $tracker) { $tracker = Get-TrackerFromConfig $config }
if (-not $tracker) { $tracker = 'unknown' }

$cli = switch ($tracker)
{
    'github' { 'gh' }
    'gitlab' { 'glab' }
    default { $null }
}

$cliAvailable = if ($cli) { [bool](Get-Command $cli -ErrorAction SilentlyContinue) } else { $false }

[pscustomobject]@{
    RepoRoot     = $repoRoot
    RepoName     = $planContext.RepoName
    Remote       = $remote
    Tracker      = $tracker
    Cli          = $cli
    CliAvailable = $cliAvailable
    ConfigPath   = $planContext.ConfigPath
    Surface      = $planContext.Surface
} | ConvertTo-Json -Depth 5
