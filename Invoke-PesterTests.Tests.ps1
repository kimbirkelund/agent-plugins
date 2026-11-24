BeforeAll {
    $script:runner = Join-Path $PSScriptRoot 'Invoke-PesterTests.ps1';

    function Invoke-Runner
    {
        param([string]$TestFile)

        $null = & pwsh -NoProfile -File $script:runner -Path $TestFile -Output None 2>&1;
        return $LASTEXITCODE;
    }
}

Describe 'Invoke-PesterTests.ps1' {
    It 'exits 0 when all tests pass' {
        $f = Join-Path $TestDrive 'Pass.Tests.ps1';
        Set-Content $f "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";
        Invoke-Runner $f | Should -Be 0;
    }

    It 'exits non-zero when a test fails' {
        $f = Join-Path $TestDrive 'Fail.Tests.ps1';
        Set-Content $f "Describe 'a' { It 'b' { 1 | Should -Be 2 } }";
        Invoke-Runner $f | Should -Not -Be 0;
    }

    It 'exits non-zero when a file throws during discovery' {
        $f = Join-Path $TestDrive 'Throw.Tests.ps1';
        Set-Content $f "throw 'boom'";
        Invoke-Runner $f | Should -Not -Be 0;
    }
}
