<#
.SYNOPSIS
    Runs all Pester tests for the PowerShell scripts in this folder.

.DESCRIPTION
    Discovers every *.Tests.ps1 under the script's own directory and runs them
    with Pester v5. Ensures a compatible Pester is available (installs it for
    the current user if missing). Exits non-zero when any test or container
    (e.g. a file that throws during discovery) fails, so it is usable as a
    CI / pre-commit gate.

    With -Workers greater than 1, each test file runs in its own child pwsh,
    at most -Workers at once, largest file first. Each child writes its counts
    and failed test names as JSON to a file the parent names; the parent prints
    each file's captured output whole when that file finishes, then one totals
    line. A child that exits without writing its result file counts as a
    failure.

.PARAMETER Path
    Optional path(s) to specific test files or folders to run instead of the
    whole folder. Defaults to this script's directory.

.PARAMETER Output
    Pester output verbosity: None, Normal, Detailed or Diagnostic. Default Detailed.

.PARAMETER Workers
    How many test files run at once, each in its own child pwsh. Defaults to
    the smaller of 4 and the processor count. 1 runs every file in this
    process, in one Pester run.

.PARAMETER WorkerFile
    Internal: the single test file a child process runs.

.PARAMETER ResultPath
    Internal: where a child process writes its JSON result.

.EXAMPLE
    ./Invoke-PesterTests.ps1

.EXAMPLE
    ./Invoke-PesterTests.ps1 -Path ./planning -Workers 1 -Output Diagnostic
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [string[]]$Path,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed',

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$Workers = [Math]::Min(4, [Environment]::ProcessorCount),

    [Parameter(ParameterSetName = 'Worker', Mandatory, DontShow)]
    [string]$WorkerFile,

    [Parameter(ParameterSetName = 'Worker', Mandatory, DontShow)]
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop';
Set-StrictMode -Version Latest;

$minPester = [version]'5.0.0';

$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge $minPester } |
    Sort-Object Version -Descending |
    Select-Object -First 1;

if (-not $pester)
{
    Write-Host "Pester >= $minPester not found; installing for current user…" -ForegroundColor Yellow;
    Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion $minPester;
    $pester = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge $minPester } |
        Sort-Object Version -Descending |
        Select-Object -First 1;
}

Import-Module Pester -MinimumVersion $minPester -Force;

if ($PSCmdlet.ParameterSetName -eq 'Worker')
{
    $config = New-PesterConfiguration;
    $config.Run.Path = @($WorkerFile);
    $config.Run.PassThru = $true;
    $config.Output.Verbosity = $Output;
    $config.TestResult.Enabled = $false;

    $result = Invoke-Pester -Configuration $config;

    [pscustomobject]@{
        Passed           = $result.PassedCount
        Failed           = $result.FailedCount
        Skipped          = $result.SkippedCount
        FailedContainers = $result.FailedContainersCount
        FailedTests      = @($result.Failed | ForEach-Object { $_.ExpandedPath })
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $ResultPath -Encoding utf8;

    exit 0;
}

Write-Host "Using Pester $($pester.Version)" -ForegroundColor DarkGray;

if (-not $Path) { $Path = @($PSScriptRoot); }

if ($Workers -le 1)
{
    $config = New-PesterConfiguration;
    $config.Run.Path = $Path;
    $config.Run.PassThru = $true;
    $config.Output.Verbosity = $Output;
    $config.TestResult.Enabled = $false;

    $result = Invoke-Pester -Configuration $config;

    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) { exit 1; }

    exit 0;
}

$files = @(@(
        foreach ($p in $Path)
        {
            $item = Get-Item -LiteralPath $p -Force;
            if ($item.PSIsContainer)
            {
                Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.Tests.ps1';
            }
            else
            {
                $item;
            }
        }
    ) | Sort-Object FullName -Unique | Sort-Object Length -Descending);

$resultDir = Join-Path ([IO.Path]::GetTempPath()) ('pester-workers-' + [guid]::NewGuid().ToString('N'));
$null = New-Item -ItemType Directory -Path $resultDir;

$self = $PSCommandPath;
$started = [Diagnostics.Stopwatch]::StartNew();
$passed = 0;
$failed = 0;
$skipped = 0;
$failedContainers = 0;
$failedNames = [Collections.Generic.List[string]]::new();
$index = 0;

try
{
    $jobs = foreach ($file in $files)
    {
        $index++;
        [pscustomobject]@{ File = $file.FullName; ResultPath = Join-Path $resultDir "$index.json" };
    }

    $jobs | ForEach-Object -ThrottleLimit $Workers -Parallel {
        $captured = & pwsh -NoProfile -File $using:self -WorkerFile $_.File -ResultPath $_.ResultPath -Output $using:Output 2>&1 |
            ForEach-Object { "$_" };
            [pscustomobject]@{
                File       = $_.File
                ResultPath = $_.ResultPath
                ExitCode   = $LASTEXITCODE
                Output     = @($captured)
            };
        } | ForEach-Object {
            Write-Host "--- $($_.File)" -ForegroundColor Cyan;
            foreach ($line in $_.Output) { Write-Host $line; }

            if (Test-Path -LiteralPath $_.ResultPath)
            {
                $r = Get-Content -LiteralPath $_.ResultPath -Raw | ConvertFrom-Json;
                $passed += $r.Passed;
                $failed += $r.Failed;
                $skipped += $r.Skipped;
                $failedContainers += $r.FailedContainers;
                foreach ($name in @($r.FailedTests)) { if ($name) { $failedNames.Add("$($_.File): $name"); } }
                if ($r.FailedContainers -gt 0) { $failedNames.Add("$($_.File): container failed"); }
            }
            else
            {
                $failedContainers++;
                $failedNames.Add("$($_.File): worker exited with code $($_.ExitCode) and wrote no result");
            }
        };
}
finally
{
    Remove-Item -LiteralPath $resultDir -Recurse -Force -ErrorAction SilentlyContinue;
}

$started.Stop();

if ($failedNames.Count -gt 0)
{
    Write-Host 'Failures:' -ForegroundColor Red;
    foreach ($name in $failedNames) { Write-Host "  $name" -ForegroundColor Red; }
}

$seconds = [Math]::Round($started.Elapsed.TotalSeconds, 2);
$colour = if ($failed -gt 0 -or $failedContainers -gt 0) { 'Red' } else { 'Green' };
Write-Host "Files: $($files.Count), Passed: $passed, Failed: $failed, Skipped: $skipped, Failed containers: $failedContainers, Wall seconds: $seconds" -ForegroundColor $colour;

if ($failed -gt 0 -or $failedContainers -gt 0) { exit 1; }

exit 0;
