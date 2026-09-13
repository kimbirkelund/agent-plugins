<#
.SYNOPSIS
    Resolve everything /pln and /impl need to know about where a plan lives: the plans
    repository, this repository's plan directory, which plan is the current one, and the
    user's configured surface and worktree hooks.

.DESCRIPTION
    Plans live in their own git repository rather than in the working tree, so neither
    command can find a plan by looking beside the code. This script is the single place
    that knows the layout, so the two skills agree on it without restating the rules.

    Layout: <plans repo>/<repo name>/<YYYY-MM-DD>-<slug>.md
    Repo name is taken from the origin remote's URL where there is one, so every worktree
    of a repository maps to the same plan directory.

    Which plan is current is decided in this order:
      1. the plan whose `Branch:` line matches the checked-out branch — exact, and the
         case /impl hits when it resumes in the worktree it created;
      2. otherwise the single plan with Status PLANNING or IMPLEMENTING;
      3. otherwise nothing, with every candidate returned so the caller can ask.

    Configuration is read from $XDG_CONFIG_HOME/claude-planning/config.json, falling back
    to ~/.config/claude-planning/config.json:

      {
        "plansRepo": "~/code/plans",
        "surface":  { "skill": "show-me" },
        "worktree": { "command": "gw {repo} {name}" },
        "session":  { "command": "wezterm start --cwd {path}" }
      }

    Every key is optional. plansRepo defaults to <code root>/plans, where the code root is
    $env:__CODE_ROOT or ~/code; $env:CLAUDE_PLANS_REPO overrides both. A hook may name a
    `skill` for the caller to invoke or a `command` to run, and `command` wins when both
    are set. A hook that is not configured is absent from the output, and the caller skips
    that step silently.

.PARAMETER Title
    Plan title to derive a new plan path from. Adds NewPlanPath to the output: a date, a
    slug of the title, and a numeric suffix if that name is taken. Nothing is created on
    disk.

.PARAMETER Date
    Date to stamp NewPlanPath with. Defaults to today. Pass the original date when placing
    a plan that already existed, so the plans directory stays in the order the work
    happened rather than the order it was filed.

.PARAMETER Path
    Work tree to resolve the context for. Defaults to the current directory.

.PARAMETER ConfigPath
    Configuration file to read instead of the default location.

.OUTPUTS
    One JSON object on stdout.

.EXAMPLE
    pwsh -File Get-PlanContext.ps1

.EXAMPLE
    pwsh -File Get-PlanContext.ps1 -Title 'move plans into their own repo'
#>
[CmdletBinding()]
param(
    [string]$Title,

    [datetime]$Date,

    [string]$Path = '.',

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop';
$PSNativeCommandUseErrorActionPreference = $false;
Set-StrictMode -Version Latest;

function Resolve-HomePath([string]$Value)
{
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $userHome = [System.Environment]::GetFolderPath('UserProfile');
    if ($Value -eq '~') { return $userHome }
    if ($Value.StartsWith('~/') -or $Value.StartsWith('~\'))
    {
        return Join-Path $userHome $Value.Substring(2);
    }

    return $Value;
}

function Get-PlanConfig([string]$ExplicitPath)
{
    $path = $ExplicitPath;
    if (-not $path)
    {
        $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.config' };
        $path = Join-Path $configHome 'claude-planning/config.json';
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf))
    {
        return [pscustomobject]@{ Path = $path; Exists = $false; Config = $null }
    }

    try
    {
        $config = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json;
    }
    catch
    {
        throw "Planning config '$path' is not valid JSON: $($_.Exception.Message)";
    }

    return [pscustomobject]@{ Path = $path; Exists = $true; Config = $config }
}

function Get-Hook($Config, [string]$Name)
{
    if (-not $Config) { return $null }
    if (-not $Config.PSObject.Properties.Name.Contains($Name)) { return $null }

    $hook = $Config.$Name;
    if ($null -eq $hook) { return $null }

    # A bare string is the command form; the object form carries `skill`, `command`, or both.
    if ($hook -is [string])
    {
        if ([string]::IsNullOrWhiteSpace($hook)) { return $null }
        return [pscustomobject]@{ Command = $hook }
    }

    $command = if ($hook.PSObject.Properties.Name.Contains('command')) { $hook.command } else { $null }
    $skill = if ($hook.PSObject.Properties.Name.Contains('skill')) { $hook.skill } else { $null }

    if (-not [string]::IsNullOrWhiteSpace($command)) { return [pscustomobject]@{ Command = $command } }
    if (-not [string]::IsNullOrWhiteSpace($skill)) { return [pscustomobject]@{ Skill = $skill } }

    return $null;
}

function Get-Slug([string]$Value)
{
    $slug = $Value.ToLowerInvariant();
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-');
    $slug = $slug.Trim('-');
    if ($slug.Length -gt 48)
    {
        $slug = $slug.Substring(0, 48).Trim('-');
    }

    if (-not $slug) { $slug = 'plan' }
    return $slug;
}

function Get-PlanHeader([string]$PlanPath)
{
    # Header fields sit in the first few lines; a plan is a page and this runs on every
    # candidate, so read the top rather than the whole file.
    $lines = Get-Content -LiteralPath $PlanPath -TotalCount 20;
    $title = $null; $status = $null; $branch = $null; $updated = $null;

    foreach ($line in $lines)
    {
        if (-not $title -and $line -match '^#\s*Plan:\s*(.+?)\s*$') { $title = $Matches[1]; continue }
        if (-not $status -and $line -match '^Status:\s*(\S+)') { $status = $Matches[1]; continue }
        if (-not $branch -and $line -match '^Branch:\s*(\S+)') { $branch = $Matches[1]; continue }
        if (-not $updated -and $line -match '^Updated:\s*(\S+)') { $updated = $Matches[1]; continue }
    }

    return [pscustomobject]@{
        Path    = $PlanPath
        Name    = Split-Path $PlanPath -Leaf
        Title   = $title
        Status  = $status
        Branch  = $branch
        Updated = $updated
    }
}

if (-not (Test-Path -LiteralPath $Path -PathType Container))
{
    throw "'$Path' is not a directory.";
}

$searchRoot = (Resolve-Path -LiteralPath $Path).Path;

$repoRoot = git -C $searchRoot rev-parse --show-toplevel 2>$null;
if ($LASTEXITCODE -ne 0 -or -not $repoRoot)
{
    throw "'$searchRoot' is not inside a git work tree, so there is no repository to plan for.";
}
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path;

$branch = git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null;
if ($LASTEXITCODE -ne 0) { $branch = $null }

# Identity must survive worktrees: every worktree of a repository plans into one
# directory. The origin URL is the most stable name available; the main work tree's
# directory name is the fallback for a repository with no remote.
$repoName = $null;
$originUrl = git -C $repoRoot remote get-url origin 2>$null;
if ($LASTEXITCODE -eq 0 -and $originUrl)
{
    $repoName = ($originUrl.Trim() -replace '\.git$', '') -split '[/:]' | Where-Object { $_ } | Select-Object -Last 1;
}

if (-not $repoName)
{
    $commonDir = git -C $repoRoot rev-parse --path-format=absolute --git-common-dir 2>$null;
    if ($LASTEXITCODE -eq 0 -and $commonDir)
    {
        $repoName = Split-Path (Split-Path $commonDir.Trim() -Parent) -Leaf;
    }
}

if (-not $repoName) { $repoName = Split-Path $repoRoot -Leaf }

$configInfo = Get-PlanConfig -ExplicitPath $ConfigPath;
$config = $configInfo.Config;

$plansRepo = Resolve-HomePath $env:CLAUDE_PLANS_REPO;
if (-not $plansRepo -and $config -and $config.PSObject.Properties.Name.Contains('plansRepo'))
{
    $plansRepo = Resolve-HomePath $config.plansRepo;
}
if (-not $plansRepo)
{
    $codeRoot = if ($env:__CODE_ROOT) { $env:__CODE_ROOT } else { Join-Path ([System.Environment]::GetFolderPath('UserProfile')) 'code' }
    $plansRepo = Join-Path $codeRoot 'plans';
}

$planDir = Join-Path $plansRepo $repoName;

$candidates = @();
if (Test-Path -LiteralPath $planDir -PathType Container)
{
    $candidates = @(Get-ChildItem -LiteralPath $planDir -Filter '*.md' -File |
            Sort-Object Name |
            ForEach-Object { Get-PlanHeader $_.FullName });
}

$planPath = $null;
$match = 'none';

$byBranch = @($candidates | Where-Object { $branch -and $_.Branch -eq $branch });
$active = @($candidates | Where-Object { $_.Status -in @('PLANNING', 'IMPLEMENTING') });

if ($byBranch.Count -eq 1)
{
    $planPath = $byBranch[0].Path;
    $match = 'branch';
}
elseif ($byBranch.Count -gt 1)
{
    $match = 'ambiguous';
}
elseif ($active.Count -eq 1)
{
    $planPath = $active[0].Path;
    $match = 'only-active';
}
elseif ($active.Count -gt 1)
{
    $match = 'ambiguous';
}

$newPlanPath = $null;
if ($Title)
{
    $stamp = if ($PSBoundParameters.ContainsKey('Date')) { $Date.ToString('yyyy-MM-dd') } else { Get-Date -Format 'yyyy-MM-dd' }
    $slug = Get-Slug $Title;
    $newPlanPath = Join-Path $planDir "$stamp-$slug.md";
    $suffix = 2;
    while (Test-Path -LiteralPath $newPlanPath -PathType Leaf)
    {
        $newPlanPath = Join-Path $planDir "$stamp-$slug-$suffix.md";
        $suffix++;
    }
}

[pscustomobject]@{
    PlansRepo       = $plansRepo
    PlansRepoExists = (Test-Path -LiteralPath (Join-Path $plansRepo '.git'))
    PlanDir         = $planDir
    RepoRoot        = $repoRoot
    RepoName        = $repoName
    Branch          = $branch
    PlanPath        = $planPath
    PlanMatch       = $match
    NewPlanPath     = $newPlanPath
    Candidates      = $candidates
    Surface         = (Get-Hook $config 'surface')
    Worktree        = (Get-Hook $config 'worktree')
    Session         = (Get-Hook $config 'session')
    ConfigPath      = $configInfo.Path
    ConfigExists    = $configInfo.Exists
} | ConvertTo-Json -Depth 5
