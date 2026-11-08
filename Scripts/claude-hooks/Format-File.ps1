<#
.SYNOPSIS
    PostToolUse hook for Write|Edit|MultiEdit|NotebookEdit: formats the edited file.
.DESCRIPTION
    Reads the hook JSON from stdin and takes tool_input.file_path (or notebook_path for NotebookEdit). Empty or unparsable
    input, or a missing file_path, exits 0. Calls Format-Path.ps1; on failure writes its
    output to stderr and exits 2 so Claude sees it.
.PARAMETER RepoRoot
    Repository root. Defaults to two levels above this script.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..')
)

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw))
{
    exit 0
}

try
{
    $toolInput = ($raw | ConvertFrom-Json -ErrorAction Stop).tool_input
    $file = $toolInput.file_path ?? $toolInput.notebook_path
}
catch
{
    exit 0
}

if ([string]::IsNullOrWhiteSpace($file))
{
    exit 0
}

$output = & (Join-Path $PSScriptRoot 'Format-Path.ps1') -Path $file -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0)
{
    [Console]::Error.WriteLine(($output -join "`n"))
    exit 2
}

exit 0
