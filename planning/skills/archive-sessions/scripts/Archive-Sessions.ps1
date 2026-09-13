<#
.SYNOPSIS
    Archive the Claude Code conversations that produced a piece of work.

.DESCRIPTION
    Copies the session transcripts for a repository into
    <ArchiveRoot>/<yyyy-MM-dd> - <repo> - <branch>/conversations.zip and writes an index.md
    describing what was archived.

    Plans are not archived and are never moved: they live in their own git repository with
    their own history, which is the record of how the thinking moved. What that repository
    does not hold is the conversation the plan came out of, and that is what this script
    files away. Pass -PlanPath to have the plan referenced in the index; it is read, never
    touched.

    The repo name comes from the origin remote (falling back to the work tree's directory
    name) and the branch is the checked-out branch (or the short SHA when detached).

    Transcripts are found by encoding candidate working directories the way Claude Code
    names its project folders (every character outside [A-Za-z0-9] becomes '-'), then kept
    when the session was still active at or after the cutoff.

    Emits one line of compressed JSON on stdout describing the result. Supports -WhatIf,
    which reports the same JSON without touching anything.

.PARAMETER ArchiveRoot
    Absolute path to the archive folder (e.g. the vault's plan-archive). Created if its
    parent exists.

.PARAMETER RepoPath
    Work tree whose sessions are being archived. Defaults to the current directory.

.PARAMETER PlanPath
    Optional plan to reference in the index. Read for its title, status and base commit;
    never moved, copied or modified. When given and -Since is not, the cutoff is the plan's
    creation time minus GraceHours and the folder is dated from the plan's creation.

.PARAMETER ProjectsRoot
    Root of Claude Code's per-project transcript folders. Defaults to ~/.claude/projects.

.PARAMETER Since
    Keep sessions still active at or after this time. Defaults to the plan-derived cutoff
    when -PlanPath is given, otherwise 7 days ago.

.PARAMETER GraceHours
    How far before the plan's creation time a session may have ended and still be
    considered part of this work. Defaults to 6. Only used with -PlanPath and without
    -Since.

.PARAMETER Date
    Date for the archive folder name. Defaults to the plan's creation date when -PlanPath
    is given, otherwise today.

.PARAMETER Force
    Overwrite an existing conversations.zip or index.md in the destination folder.

.OUTPUTS
    Compressed JSON on stdout.

    Exit codes: 0 success, 1 plan file not found, 2 unusable archive root,
    3 destination already populated (use -Force), 4 not a git work tree, 5 other failure.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ArchiveRoot,

    [string]$RepoPath = '.',

    [string]$PlanPath,

    [string]$ProjectsRoot = (Join-Path $HOME '.claude/projects'),

    [datetime]$Since,

    [double]$GraceHours = 6,

    [datetime]$Date,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Fail
{
    param([string]$Message, [int]$Code)

    [Console]::Error.WriteLine("error: $Message")
    exit $Code
}

function Get-EncodedProjectName
{
    param([string]$Path)

    return ($Path -replace '[^A-Za-z0-9]', '-')
}

function Get-SafeNameComponent
{
    param([string]$Value)

    $safe = $Value -replace '[\\/:*?"<>|#^\[\]]', '-'
    $safe = $safe -replace '\s+', ' '
    return $safe.Trim().Trim('-')
}

function Invoke-Git
{
    param([string]$RepoDir, [string[]]$GitArgs)

    $output = & git -C $RepoDir @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0)
    {
        return $null
    }
    if ($null -eq $output)
    {
        return $null
    }
    return ([string]($output | Select-Object -First 1)).Trim()
}

function Get-SessionCwd
{
    param([string]$JsonlPath)

    try
    {
        $lines = Get-Content -LiteralPath $JsonlPath -TotalCount 200 -ErrorAction Stop
    }
    catch
    {
        return $null
    }

    foreach ($line in $lines)
    {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '"cwd"')
        {
            continue
        }
        try
        {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch
        {
            continue
        }
        if ($entry.PSObject.Properties.Name -contains 'cwd' -and $entry.cwd)
        {
            return [string]$entry.cwd
        }
    }

    return $null
}

function Get-SessionStart
{
    param([string]$JsonlPath)

    try
    {
        $lines = Get-Content -LiteralPath $JsonlPath -TotalCount 200 -ErrorAction Stop
    }
    catch
    {
        return $null
    }

    foreach ($line in $lines)
    {
        if ($line -match '"timestamp"\s*:\s*"([^"]+)"')
        {
            try
            {
                return [datetime]::Parse($Matches[1], $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            }
            catch
            {
                return $null
            }
        }
    }

    return $null
}

function Format-Size
{
    param([long]$Bytes)

    if ($Bytes -ge 1MB)
    {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB)
    {
        return ('{0:N0} KB' -f ($Bytes / 1KB))
    }
    return ('{0} B' -f $Bytes)
}

# --- Validate inputs -------------------------------------------------------------------

$planFile = $null
if ($PlanPath)
{
    if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf))
    {
        Write-Fail "plan file not found: $PlanPath" 1
    }
    $planFile = Get-Item -LiteralPath $PlanPath
}

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container))
{
    Write-Fail "repository path is not a directory: $RepoPath" 4
}
$searchDir = (Resolve-Path -LiteralPath $RepoPath).Path

$archiveParent = Split-Path -Parent $ArchiveRoot
if ([string]::IsNullOrWhiteSpace($archiveParent) -or -not (Test-Path -LiteralPath $archiveParent -PathType Container))
{
    Write-Fail "archive root's parent directory does not exist: $archiveParent" 2
}
if ((Test-Path -LiteralPath $ArchiveRoot) -and -not (Test-Path -LiteralPath $ArchiveRoot -PathType Container))
{
    Write-Fail "archive root exists but is not a directory: $ArchiveRoot" 2
}

# --- Identify the repository ------------------------------------------------------------

$repoRoot = Invoke-Git -RepoDir $searchDir -GitArgs @('rev-parse', '--show-toplevel')
if (-not $repoRoot)
{
    Write-Fail "not inside a git work tree: $searchDir" 4
}

$remoteUrl = Invoke-Git -RepoDir $repoRoot -GitArgs @('remote', 'get-url', 'origin')
if ($remoteUrl)
{
    $repoName = [System.IO.Path]::GetFileName($remoteUrl.TrimEnd('/', '\'))
    if ($repoName -match '\.git$')
    {
        $repoName = $repoName.Substring(0, $repoName.Length - 4)
    }
}
else
{
    $repoName = [System.IO.Path]::GetFileName($repoRoot)
}

$branch = Invoke-Git -RepoDir $repoRoot -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
if (-not $branch -or $branch -eq 'HEAD')
{
    $branch = Invoke-Git -RepoDir $repoRoot -GitArgs @('rev-parse', '--short', 'HEAD')
    if (-not $branch)
    {
        $branch = 'no-branch'
    }
}

# --- Read what the plan says about itself, if there is one -----------------------------

$planTitle = $null
$planStatus = $null
$planBase = $null
$planCommit = $null

if ($planFile)
{
    $planText = Get-Content -LiteralPath $planFile.FullName -Raw
    $planTitle = if ($planText -match '(?m)^#\s+(.+?)\s*$') { $Matches[1] } else { $planFile.BaseName }
    $planStatus = if ($planText -match '(?m)^Status:\s*(\S+)') { $Matches[1] } else { 'unknown' }
    $planBase = if ($planText -match '(?m)^Base:\s*(\S+)') { $Matches[1] } else { $null }

    # The plan stays put, so the index records where it is and which commit of the plans
    # repository this archive was taken beside.
    $planCommit = Invoke-Git -RepoDir $planFile.Directory.FullName -GitArgs @('rev-parse', 'HEAD')
}

# --- Destination -----------------------------------------------------------------------

$planCreated = $null
if ($planFile)
{
    $planCreated = $planFile.CreationTime
    if ($planCreated.Year -le 1601 -or $planCreated -gt $planFile.LastWriteTime)
    {
        $planCreated = $planFile.LastWriteTime
    }
}

$folderDate = if ($PSBoundParameters.ContainsKey('Date')) { $Date } elseif ($planCreated) { $planCreated } else { Get-Date }

$folderName = '{0} - {1} - {2}' -f $folderDate.ToString('yyyy-MM-dd'), (Get-SafeNameComponent $repoName), (Get-SafeNameComponent $branch)
$destDir = Join-Path $ArchiveRoot $folderName
$destZip = Join-Path $destDir 'conversations.zip'
$destIndex = Join-Path $destDir 'index.md'

if (-not $Force)
{
    foreach ($existing in @($destZip, $destIndex))
    {
        if (Test-Path -LiteralPath $existing)
        {
            Write-Fail "destination already has $(Split-Path -Leaf $existing): $existing (use -Force to overwrite)" 3
        }
    }
}

# --- Find the conversations ------------------------------------------------------------

$cutoff = if ($PSBoundParameters.ContainsKey('Since')) { $Since }
elseif ($planCreated) { $planCreated.AddHours(-$GraceHours) }
else { (Get-Date).AddDays(-7) }

$candidatePaths = @($repoRoot)
if ($searchDir -ne $repoRoot)
{
    $candidatePaths += $searchDir
}
$exactNames = @($candidatePaths | ForEach-Object { Get-EncodedProjectName $_ } | Select-Object -Unique)
$repoPrefix = (Get-EncodedProjectName $repoRoot) + '-'

$projectDirs = @()
if (Test-Path -LiteralPath $ProjectsRoot -PathType Container)
{
    foreach ($dir in (Get-ChildItem -LiteralPath $ProjectsRoot -Directory))
    {
        if ($exactNames -contains $dir.Name)
        {
            $projectDirs += $dir
            continue
        }
        if (-not $dir.Name.StartsWith($repoPrefix))
        {
            continue
        }
        # A prefix match may be a sibling work tree rather than a subdirectory of this one
        # ('-…-safepilot-' also prefixes '-…-safepilot-4108-…'), so confirm against the cwd
        # the sessions actually recorded.
        $sample = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File | Select-Object -First 1
        if (-not $sample)
        {
            continue
        }
        $cwd = Get-SessionCwd -JsonlPath $sample.FullName
        if ($cwd -and ($cwd -eq $repoRoot -or $cwd.StartsWith($repoRoot.TrimEnd('/') + '/')))
        {
            $projectDirs += $dir
        }
    }
}

$sessions = @()
foreach ($dir in $projectDirs)
{
    foreach ($file in (Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File))
    {
        if ($file.LastWriteTime -lt $cutoff)
        {
            continue
        }
        $sessions += [pscustomobject]@{
            sessionId  = $file.BaseName
            projectDir = $dir.Name
            sourcePath = $file.FullName
            start      = Get-SessionStart -JsonlPath $file.FullName
            end        = $file.LastWriteTime
            sizeBytes  = $file.Length
        }
    }
}
$sessions = @($sessions | Sort-Object -Property @{ Expression = { if ($_.start) { $_.start } else { $_.end } } })

# --- Result (reported even under -WhatIf) ----------------------------------------------

$result = [pscustomobject]@{
    archiveFolder = $destDir
    indexDest     = $destIndex
    zipDest       = $destZip
    repo          = $repoName
    repoRoot      = $repoRoot
    branch        = $branch
    planPath      = if ($planFile) { $planFile.FullName } else { $null }
    planTitle     = $planTitle
    planStatus    = $planStatus
    planBase      = $planBase
    planCommit    = $planCommit
    planCreated   = if ($planCreated) { $planCreated.ToString('s') } else { $null }
    cutoff        = $cutoff.ToString('s')
    projectDirs   = @($projectDirs | ForEach-Object { $_.Name })
    sessionCount  = $sessions.Count
    sessions      = @($sessions | ForEach-Object {
            [pscustomobject]@{
                sessionId  = $_.sessionId
                projectDir = $_.projectDir
                start      = if ($_.start) { $_.start.ToString('s') } else { $null }
                end        = $_.end.ToString('s')
                sizeBytes  = $_.sizeBytes
            }
        })
    whatIf        = [bool]$WhatIfPreference
}

if ($WhatIfPreference)
{
    Write-Output ($result | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

# --- Do the work -----------------------------------------------------------------------

try
{
    if ($PSCmdlet.ShouldProcess($destDir, 'Create archive folder'))
    {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    if ($sessions.Count -gt 0 -and $PSCmdlet.ShouldProcess($destZip, "Write $($sessions.Count) transcript(s)"))
    {
        if (Test-Path -LiteralPath $destZip)
        {
            Remove-Item -LiteralPath $destZip -Force
        }
        $zip = [System.IO.Compression.ZipFile]::Open($destZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try
        {
            foreach ($session in $sessions)
            {
                $entryName = '{0}/{1}.jsonl' -f $session.projectDir, $session.sessionId
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $session.sourcePath, $entryName) | Out-Null
            }
        }
        finally
        {
            $zip.Dispose()
        }
    }

    if ($PSCmdlet.ShouldProcess($destIndex, 'Write index.md'))
    {
        $lines = [System.Collections.Generic.List[string]]::new()
        $heading = if ($planTitle) { $planTitle } else { "$repoName - $branch" }
        $lines.Add("# $heading")
        $lines.Add('')
        $lines.Add("- Repo: $repoName (``$repoRoot``)")
        $lines.Add("- Branch: ``$branch``")
        if ($planFile)
        {
            # The plan is not copied here: it stays in the plans repository, where its own
            # history is the record. This is a pointer, with the commit it pointed at.
            $lines.Add("- Plan: ``$($planFile.FullName)`` (not moved; kept in the plans repository)")
            $lines.Add("- Plan created: $($planCreated.ToString('yyyy-MM-dd HH:mm'))")
            $lines.Add("- Status at archive: $planStatus")
            if ($planCommit)
            {
                $lines.Add("- Plans repo commit: ``$planCommit``")
            }
            if ($planBase)
            {
                $lines.Add("- Base commit: ``$planBase``")
            }
        }
        $lines.Add("- Archived: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
        $lines.Add('')
        $lines.Add('## Conversations')
        $lines.Add('')
        if ($sessions.Count -eq 0)
        {
            $lines.Add("No session transcripts were active at or after $($cutoff.ToString('yyyy-MM-dd HH:mm')) for this repository.")
        }
        else
        {
            $lines.Add("$($sessions.Count) session transcript(s) in ``conversations.zip``, kept because they were still active at or after $($cutoff.ToString('yyyy-MM-dd HH:mm')).")
            $lines.Add('')
            $lines.Add('| Session | First message | Last activity | Size | Project dir |')
            $lines.Add('| --- | --- | --- | --- | --- |')
            foreach ($session in $sessions)
            {
                $startText = if ($session.start) { $session.start.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
                $lines.Add(('| `{0}` | {1} | {2} | {3} | `{4}` |' -f $session.sessionId, $startText, $session.end.ToString('yyyy-MM-dd HH:mm'), (Format-Size $session.sizeBytes), $session.projectDir))
            }
        }
        $lines.Add('')
        Set-Content -LiteralPath $destIndex -Value ($lines -join "`n") -NoNewline
    }
}
catch
{
    Write-Fail $_.Exception.Message 5
}

Write-Output ($result | ConvertTo-Json -Depth 5 -Compress)
exit 0
