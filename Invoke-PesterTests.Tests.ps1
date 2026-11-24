BeforeAll {
    $script:runner = Join-Path $PSScriptRoot 'Invoke-PesterTests.ps1';

    function Invoke-Runner
    {
        param([string]$TestFile)

        $null = & pwsh -NoProfile -File $script:runner -Path $TestFile -Output None -Workers 1 2>&1;
        return $LASTEXITCODE;
    }

    function Invoke-ParallelRunner
    {
        param(
            [string[]]$TestPath,
            [string]$Output = 'None'
        )

        $lines = @(& pwsh -NoProfile -File $script:runner -Path $TestPath -Output $Output -Workers 2 2>&1 | ForEach-Object { "$_" });
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines };
    }

    function New-TestFile
    {
        param([string]$Directory, [string]$Name, [string]$Content)

        $null = New-Item -ItemType Directory -Path $Directory -Force;
        $f = Join-Path $Directory $Name;
        Set-Content -LiteralPath $f -Value $Content;
        return $f;
    }
}

Describe 'Invoke-PesterTests.ps1 with -Workers 1' {
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

Describe 'Invoke-PesterTests.ps1 with -Workers 2' {
    It 'exits 0 and sums the counts when every file passes' {
        $dir = Join-Path $TestDrive 'allpass';
        $null = New-TestFile $dir 'One.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 }; It 'c' { 1 | Should -Be 1 } }";
        $null = New-TestFile $dir 'Two.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 }; It 'c' -Skip { 1 | Should -Be 2 } }";
        $null = New-TestFile $dir 'Three.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 0;
        @($run.Lines | Where-Object { $_ -match '^Files: 3, Passed: 4, Failed: 0, Skipped: 1, Failed containers: 0, Wall seconds: ' }).Count | Should -Be 1;
    }

    It 'exits non-zero when one file has a failing test' {
        $dir = Join-Path $TestDrive 'onefail';
        $null = New-TestFile $dir 'Good.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";
        $null = New-TestFile $dir 'Bad.Tests.ps1' "Describe 'a' { It 'broken' { 1 | Should -Be 2 } }";

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 1;
        @($run.Lines | Where-Object { $_ -match '^Files: 2, Passed: 1, Failed: 1, ' }).Count | Should -Be 1;
        @($run.Lines | Where-Object { $_ -match 'Bad\.Tests\.ps1: a\.broken' }).Count | Should -Be 1;
    }

    It 'exits non-zero when a file throws during discovery' {
        $dir = Join-Path $TestDrive 'discovery';
        $null = New-TestFile $dir 'Good.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";
        $null = New-TestFile $dir 'Throw.Tests.ps1' "throw 'boom'";

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 1;
        @($run.Lines | Where-Object { $_ -match 'Failed containers: 1,' }).Count | Should -Be 1;
    }

    It 'exits non-zero when a worker dies without writing its result' {
        $dir = Join-Path $TestDrive 'dies';
        $null = New-TestFile $dir 'Good.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";
        $null = New-TestFile $dir 'Dies.Tests.ps1' '[Environment]::Exit(3)';

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 1;
        @($run.Lines | Where-Object { $_ -match 'Dies\.Tests\.ps1: worker exited with code 3 and wrote no result' }).Count | Should -Be 1;
    }

    It 'prints each file output as one contiguous block' {
        $dir = Join-Path $TestDrive 'blocks';
        $alpha = (1..4 | ForEach-Object { "It 'alpha$_' { Start-Sleep -Milliseconds 200 }" }) -join '; ';
        $beta = (1..4 | ForEach-Object { "It 'beta$_' { Start-Sleep -Milliseconds 200 }" }) -join '; ';
        $null = New-TestFile $dir 'Alpha.Tests.ps1' "Describe 'a' { $alpha }";
        $null = New-TestFile $dir 'Beta.Tests.ps1' "Describe 'b' { $beta }";

        $run = Invoke-ParallelRunner $dir -Output Detailed;

        $run.ExitCode | Should -Be 0;
        foreach ($name in 'alpha', 'beta')
        {
            $hits = @(for ($i = 0; $i -lt $run.Lines.Count; $i++) { if ($run.Lines[$i] -match "\b$name\d\b") { $i } });
            $hits.Count | Should -Be 4;
            $between = $run.Lines[$hits[0]..$hits[-1]];
            $other = if ($name -eq 'alpha') { 'beta' } else { 'alpha' };
            @($between | Where-Object { $_ -match "\b$other\d\b" }).Count | Should -Be 0;
        }
    }

    It 'skips test files inside dot-directories' {
        $dir = Join-Path $TestDrive 'hidden';
        $null = New-TestFile $dir 'Good.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 1 } }";
        $null = New-TestFile (Join-Path $dir '.worktrees') 'Hidden.Tests.ps1' "Describe 'a' { It 'b' { 1 | Should -Be 2 } }";

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 0;
        @($run.Lines | Where-Object { $_ -match '^Files: 1, Passed: 1, Failed: 0, ' }).Count | Should -Be 1;
    }

    It 'starts the largest files first and never runs more than two at once' {
        $dir = Join-Path $TestDrive 'order';
        $log = Join-Path $TestDrive 'order-log';
        $null = New-Item -ItemType Directory -Path $log -Force;
        $sizes = [ordered]@{ A = 4000; B = 3000; C = 2000; D = 1000 };
        foreach ($name in $sizes.Keys)
        {
            $body = @(
                "Describe 'a' { It 'b' {"
                "    `$log = '$log';"
                "    `$null = New-Item -ItemType File -Path (Join-Path `$log 'running-$name');"
                "    `$count = @(Get-ChildItem -LiteralPath `$log -Filter 'running-*').Count;"
                "    Set-Content -LiteralPath (Join-Path `$log 'start-$name') -Value `"`$([DateTime]::UtcNow.Ticks) `$count`";"
                '    Start-Sleep -Milliseconds 500;'
                "    Remove-Item -LiteralPath (Join-Path `$log 'running-$name');"
                '} }'
                '#' + ('x' * $sizes[$name])
            ) -join "`n";
            $null = New-TestFile $dir "$name.Tests.ps1" $body;
        }

        $run = Invoke-ParallelRunner $dir;

        $run.ExitCode | Should -Be 0;
        $starts = foreach ($name in $sizes.Keys)
        {
            $ticks, $count = (Get-Content -LiteralPath (Join-Path $log "start-$name") -Raw).Trim() -split ' ';
            [pscustomobject]@{ Name = $name; Ticks = [long]$ticks; Count = [int]$count };
        }
        $order = @($starts | Sort-Object Ticks | ForEach-Object Name);
        ($order[0..1] | Sort-Object) -join ',' | Should -Be 'A,B';
        ($order[2..3] | Sort-Object) -join ',' | Should -Be 'C,D';
        ($starts | Measure-Object Count -Maximum).Maximum | Should -BeLessOrEqual 2;
    }
}
