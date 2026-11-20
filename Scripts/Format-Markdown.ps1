<#
.SYNOPSIS
    Formats and lints Markdown files: prettier, markdownlint-cli2 --fix, prettier, markdownlint-cli2.
.DESCRIPTION
    Prettier runs first so prose is wrapped before
    markdownlint judges it, markdownlint-cli2 --fix applies what it can, prettier runs again so
    its formatting wins, and markdownlint-cli2 in check mode reports what is left. Findings are
    printed on stdout as "path:line rule message" and the script exits 1; otherwise it exits 0.
    markdownlint-cli2 resolves to the one on PATH, else to "npx --yes markdownlint-cli2".
    With neither, lint is skipped silently; a missing prettier skips the prettier passes.
    The markdownlint config is .markdownlint.jsonc in RepoRoot, when present.
.PARAMETER Path
    Files to format. Relative paths resolve against the current directory. A missing file
    produces a warning and is skipped.
.PARAMETER RepoRoot
    Repository root. Defaults to one level above this script.
.PARAMETER LintTimeoutSeconds
    One time budget shared by both markdownlint-cli2 calls. When it runs out the running
    process is killed and lint is skipped silently, like a missing tool. Defaults to 80, under
    the 120 s hook timeout.
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..'),
    [int]$LintTimeoutSeconds = 80
)

$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\')
$sep = [IO.Path]::DirectorySeparatorChar
$config = Join-Path $root '.markdownlint.jsonc'
$failures = [System.Collections.Generic.List[string]]::new()

$files = [System.Collections.Generic.List[string]]::new()
foreach ($item in $Path)
{
    if ([string]::IsNullOrWhiteSpace($item))
    {
        continue
    }

    $full = [IO.Path]::GetFullPath($item, (Get-Location).ProviderPath)
    if (Test-Path -LiteralPath $full -PathType Leaf)
    {
        $files.Add($full)
    }
    else
    {
        Write-Warning "Skipping missing file: $item"
    }
}

if ($files.Count -eq 0)
{
    exit 0
}

function Get-RelativePath
{
    param([string]$Full)

    if ($Full.StartsWith($root + $sep, [StringComparison]::OrdinalIgnoreCase))
    {
        return $Full.Substring($root.Length + 1).Replace('\', '/')
    }

    $Full
}

$prettierScript = Join-Path $PSScriptRoot 'Format-Prettier.ps1'
$lintCommand = Get-Command markdownlint-cli2 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$linter = @()
if ($lintCommand)
{
    $linter = @($lintCommand.Source)
}
else
{
    $npx = Get-Command npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npx)
    {
        $linter = @($npx.Source, '--yes', 'markdownlint-cli2')
    }
}

# Runs prettier on one file. Returns $false and records the failure when prettier fails.
function Invoke-Prettier
{
    param([string]$File)

    $output = & $prettierScript -Path $File -RepoRoot $root
    if ($LASTEXITCODE -ne 0)
    {
        foreach ($line in $output)
        {
            $failures.Add([string]$line)
        }

        return $false
    }

    $true
}

# Runs the linter with a deadline. Returns $null when it cannot run or times out, which the
# caller treats as a missing tool; otherwise the exit code and output lines.
function Invoke-Linter
{
    param([string[]]$Arguments)

    $remaining = $LintTimeoutSeconds - $lintClock.Elapsed.TotalSeconds
    if ($remaining -le 0)
    {
        return $null
    }

    $extra = (Test-Path -LiteralPath $config) ? @('--config', $config) : @()
    $info = [Diagnostics.ProcessStartInfo]::new($linter[0])
    $info.WorkingDirectory = $root
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @($linter | Select-Object -Skip 1) + $extra + $Arguments + @($goodFiles | ForEach-Object { ":$_" }))
    {
        $info.ArgumentList.Add($argument)
    }

    try
    {
        $process = [Diagnostics.Process]::Start($info)
    }
    catch
    {
        return $null
    }

    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit([TimeSpan]::FromSeconds($remaining)))
    {
        $process.Kill($true)
        $process.WaitForExit()
        return $null
    }

    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = @(($out.Result + $err.Result) -split "`r?`n" | Where-Object { $_ -ne '' })
    }
}

$lintClock = [Diagnostics.Stopwatch]::StartNew()
$goodFiles = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files)
{
    if (Invoke-Prettier -File $file)
    {
        $goodFiles.Add($file)
    }
}

if ($linter.Count -gt 0 -and $goodFiles.Count -gt 0)
{
    $fixRun = Invoke-Linter -Arguments @('--fix')
    if ($fixRun)
    {
        $remaining = @($goodFiles)
        $goodFiles.Clear()
        foreach ($file in $remaining)
        {
            if (Invoke-Prettier -File $file)
            {
                $goodFiles.Add($file)
            }
        }

        $run = $goodFiles.Count -gt 0 ? (Invoke-Linter -Arguments @()) : $null
        if ($run)
        {
            $parsed = 0
            foreach ($line in $run.Output)
            {
                if ($line -match '^(?<file>.+?):(?<line>\d+)(?::\d+)? (?:(?:error|warning) )?(?<rule>MD\d+)\S* (?<message>.*)$')
                {
                    $parsed++
                    $failures.Add("$(Get-RelativePath ([IO.Path]::GetFullPath($Matches.file, $root))):$($Matches.line) $($Matches.rule) $($Matches.message)")
                }
            }

            # npm or npx failing before markdownlint-cli2 runs is a missing tool, not a finding.
            $npmFailure = $run.Output | Where-Object { $_ -match 'npm (ERR|error)' }
            if ($run.ExitCode -ne 0 -and $parsed -eq 0 -and -not $npmFailure)
            {
                $failures.Add("markdownlint-cli2 failed`n$($run.Output -join "`n")")
            }
        }
    }
}

if ($failures.Count -gt 0)
{
    $failures
    exit 1
}

exit 0
