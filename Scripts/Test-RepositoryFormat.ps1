<#
.SYNOPSIS
    Checks that every git-tracked file is formatted and lint-clean.
.DESCRIPTION
    Lists "git ls-files" under RepoRoot, keeps the files that exist and groups them by
    extension: PowerShell (.ps1 .psm1 .psd1), JSON/YAML (.json .jsonc .yml .yaml) and Markdown
    (.md). Each file is hashed, each formatter runs once on its group, and the
    files are hashed again. The formatters' findings are printed as they come, followed by one
    "path: not formatted" line per file whose hash changed. Formatting is done in place, so a
    failing run leaves the files rewritten. Exits 1 if any formatter exited non-zero or any
    hash changed; otherwise 0.
.PARAMETER RepoRoot
    Repository root. Defaults to one level above this script.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')

$groups = @(
    @{ Script = 'Format-PowerShell.ps1'; Extensions = @('.ps1', '.psm1', '.psd1'); Extra = @{} }
    @{ Script = 'Format-Prettier.ps1'; Extensions = @('.json', '.jsonc', '.yml', '.yaml'); Extra = @{} }
    @{ Script = 'Format-Markdown.ps1'; Extensions = @('.md'); Extra = @{ LintTimeoutSeconds = 600 } }
)

$tracked = @(git -C $root ls-files)
if ($LASTEXITCODE -ne 0)
{
    throw "git ls-files failed in $root"
}

$known = @($groups | ForEach-Object { $_.Extensions } | ForEach-Object { $_ })
$files = @($tracked | Where-Object { $_ } | ForEach-Object { Join-Path $root $_ } | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and ($known -contains [IO.Path]::GetExtension($_).ToLowerInvariant()) })

if ($files.Count -eq 0)
{
    "no tracked files to check under $root (none match a format group)"
    exit 1
}

$before = @{}
foreach ($file in $files)
{
    $before[$file] = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
}

$failed = $false
foreach ($group in $groups)
{
    $selected = @($files | Where-Object { $group.Extensions -contains [IO.Path]::GetExtension($_).ToLowerInvariant() })
    if ($selected.Count -eq 0)
    {
        continue
    }

    $extra = $group.Extra
    & (Join-Path $PSScriptRoot $group.Script) -Path $selected -RepoRoot $root @extra
    if ($LASTEXITCODE -ne 0)
    {
        $failed = $true
    }
}

foreach ($file in $files)
{
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $before[$file])
    {
        "$($file.Substring($root.Length + 1).Replace('\', '/')): not formatted"
        $failed = $true
    }
}

exit ($failed ? 1 : 0)
