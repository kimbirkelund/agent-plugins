<#
.SYNOPSIS
    Runs all Pester tests for the PowerShell scripts in this folder.

.DESCRIPTION
    Discovers every *.Tests.ps1 under the script's own directory and runs them
    with Pester v5. Ensures a compatible Pester is available (installs it for
    the current user if missing). Exits non-zero when any test fails, so it is
    usable as a CI / pre-commit gate.

.PARAMETER Path
    Optional path(s) to specific test files or folders to run instead of the
    whole folder. Defaults to this script's directory.

.PARAMETER Output
    Pester output verbosity: None, Normal, Detailed or Diagnostic. Default Detailed.

.EXAMPLE
    ./Invoke-ProfilePowershellPesterTests.ps1

.EXAMPLE
    ./Invoke-ProfilePowershellPesterTests.ps1 -Path ./gw.Tests.ps1 -Output Diagnostic
#>
[CmdletBinding()]
PARAM(
    [string[]]$Path,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed'
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
Write-Host "Using Pester $($pester.Version)" -ForegroundColor DarkGray;

if (-not $Path) { $Path = @($PSScriptRoot); }

$config = New-PesterConfiguration;
$config.Run.Path = $Path;
$config.Run.PassThru = $true;
$config.Output.Verbosity = $Output;
$config.TestResult.Enabled = $false;

$result = Invoke-Pester -Configuration $config;

exit $result.FailedCount;
