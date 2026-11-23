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
      1. the host part of the origin remote: if it contains the word `github` (any casing)
         and not `gitlab`, the tracker is `github`; if it contains `gitlab` and not
         `github`, `gitlab`. The host part is, by form: for a URL (`<scheme>://...`) the
         authority, between `://` and the next `/`; for `git@host:path` or any other
         scp-style `host:path`, everything before the first `:`; for anything else (a local
         path) nothing. The path is never inspected, so a repository called `github-tools`
         on another host does not match. A host part with both words or neither gives no
         match;
      2. otherwise the `issueTracker` key in the shared planning config, for a self-hosted
         instance whose host name gives nothing away - value `github` or `gitlab`;
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

function Get-RemoteHostPart([string]$Url)
{
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }

    $value = $Url.Trim();

    # scheme://[user@]host[:port]/path - the host part is the authority, up to the first '/'
    # after the scheme.
    if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://([^/\s]*)')
    {
        return $Matches[1];
    }

    # scp-like syntax carries no scheme: [user@]host:path, including `git@host:path`. The
    # host part is everything before the first ':'. A value with a '/' before any ':' is a
    # local path, not scp-like.
    if ($value -match '^([^:/\s]+):')
    {
        return $Matches[1];
    }

    return $null;
}

function Get-TrackerFromHost([string]$HostPart)
{
    if (-not $HostPart) { return $null }

    $github = $HostPart -match '(?i)github';
    $gitlab = $HostPart -match '(?i)gitlab';

    # Both words or neither: the host part does not say, so fall through to the config.
    if ($github -and -not $gitlab) { return 'github' }
    if ($gitlab -and -not $github) { return 'gitlab' }

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

$tracker = Get-TrackerFromHost (Get-RemoteHostPart $remote);
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
