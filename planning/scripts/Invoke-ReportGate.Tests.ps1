BeforeAll {
    $script:Script = Join-Path $PSScriptRoot 'Invoke-ReportGate.ps1'
    $script:Prefix = 'Deliver your completion report to the lead via SendMessage'

    function script:ConvertTo-Line
    {
        param([hashtable] $Entry)
        if (-not $Entry.ContainsKey('agentId'))
        {
            $Entry.agentId = 'a1'
        }
        $Entry | ConvertTo-Json -Depth 8 -Compress
    }

    function script:New-Assignment
    {
        param([string] $Text = '<teammate-message teammate_id="team-lead">do it</teammate-message>')
        ConvertTo-Line @{ type = 'user'; message = @{ role = 'user'; content = $Text } }
    }

    function script:New-Prose
    {
        ConvertTo-Line @{ type = 'assistant'; message = @{ role = 'assistant'; content = @(@{ type = 'text'; text = 'done' }) } }
    }

    function script:New-Report
    {
        ConvertTo-Line @{
            type    = 'assistant'
            message = @{ role = 'assistant'; content = @(@{ type = 'tool_use'; name = 'SendMessage'; input = @{ to = 'team-lead' } }) }
        }
    }

    function script:New-ToolResult
    {
        ConvertTo-Line @{
            type    = 'user'
            message = @{ role = 'user'; content = @(@{ type = 'tool_result'; tool_use_id = 'x'; content = '<teammate-message>fake' }) }
        }
    }

    # Runs the hook as a child process; returns exit code, stdout and stderr.
    function script:Invoke-Gate
    {
        param([string] $InputJson, [string] $StateRoot)
        $errFile = Join-Path $TestDrive 'stderr.txt'
        $out = & pwsh -NoProfile -File $script:Script -InputJson $InputJson -StateRoot $StateRoot -FlushDelayMs 0 2>$errFile
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Stdout   = ($out -join "`n")
            Stderr   = (Get-Content -LiteralPath $errFile -Raw)
        }
    }

    function script:New-Payload
    {
        param([hashtable] $Override = @{})
        $payload = @{ session_id = 's1'; agent_id = 'a1'; teammate_name = 'mate'; transcript_path = $script:Lead }
        foreach ($name in $Override.Keys)
        {
            $payload[$name] = $Override[$name]
        }
        $payload | ConvertTo-Json -Compress
    }

    function script:Get-State
    {
        $file = Join-Path $TestDrive 'state' 'report-gate' 's1.json'
        if (Test-Path $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    }
}

Describe 'Invoke-ReportGate' {
    BeforeEach {
        $script:State = Join-Path $TestDrive 'state'
        # transcript_path is the lead's; the teammate's file is derived beside it.
        $script:Lead = Join-Path $TestDrive 's1.jsonl'
        $script:Transcript = Join-Path $TestDrive 's1' 'subagents' 'agent-a1.jsonl'
        Remove-Item $script:State, (Join-Path $TestDrive 's1'), $script:Lead -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force (Split-Path $script:Transcript) | Out-Null
        Set-Content $script:Lead ''
    }

    Context 'report present' {
        It 'exits 0 and removes the state key' {
            New-Item -ItemType Directory -Force (Join-Path $script:State 'report-gate') | Out-Null
            Set-Content (Join-Path $script:State 'report-gate' 's1.json') '{"s1:a1":1}'
            Set-Content $script:Transcript @((New-Assignment), (New-Report))
            $r = Invoke-Gate (New-Payload) $script:State
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeNullOrEmpty
            (Get-State).ContainsKey('s1:a1') | Should -BeFalse
        }

        It 'exits 0 when the lead transcript holds no SendMessage' {
            Set-Content $script:Transcript @((New-Assignment), (New-Report))
            Set-Content $script:Lead @((New-Assignment), (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'ignores a SendMessage made before the last assignment' {
            Set-Content $script:Transcript @((New-Assignment), (New-Report), (New-Assignment), (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }
    }

    Context 'no report' {
        BeforeEach {
            Set-Content $script:Transcript @((New-Assignment), (New-Prose))
        }

        It 'pushes back with the prefix and counts 1' {
            $r = Invoke-Gate (New-Payload) $script:State
            $r.ExitCode | Should -Be 2
            $r.Stderr | Should -BeLike "$($script:Prefix)*"
            (Get-State)['s1:a1'] | Should -Be 1
        }

        It 'counts 2 on the second idle' {
            1..2 | ForEach-Object { $r = Invoke-Gate (New-Payload) $script:State }
            $r.ExitCode | Should -Be 2
            (Get-State)['s1:a1'] | Should -Be 2
        }

        It 'gives up on the third idle with -1 and a stdout line' {
            1..3 | ForEach-Object { $r = Invoke-Gate (New-Payload) $script:State }
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -Be 'ReportGateHook: s1:a1 idled without a delivered report'
            (Get-State)['s1:a1'] | Should -Be -1
        }

        It 'stays silent on the fourth idle and keeps -1' {
            1..4 | ForEach-Object { $r = Invoke-Gate (New-Payload) $script:State }
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $r.Stderr | Should -BeNullOrEmpty
            (Get-State)['s1:a1'] | Should -Be -1
        }

        It 'keys on agent_id, not teammate_name' {
            Invoke-Gate (New-Payload) $script:State | Out-Null
            (Get-State).ContainsKey('s1:a1') | Should -BeTrue
            (Get-State).ContainsKey('s1:mate') | Should -BeFalse
        }

        It 'pushes back when only the lead transcript holds a SendMessage' {
            Set-Content $script:Lead @((New-Assignment), (New-Report))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }
    }

    Context 'what counts as an assignment' {
        It 'does not count the feedback wrapped in a teammate-message tag as an assignment' {
            $wrapped = New-Assignment "<teammate-message teammate_id=`"system`">$($script:Prefix) as one fenced json block</teammate-message>"
            Set-Content $script:Transcript @((New-Assignment), (New-Report), $wrapped, (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'does not count a tool_result entry as an assignment' {
            Set-Content $script:Transcript @((New-Assignment), (New-Report), (New-ToolResult), (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'does not count feedback wrapped in a tag with a greater-than sign in an attribute' {
            $wrapped = New-Assignment "<teammate-message teammate_id=`"system`" summary=`"a > b`">$($script:Prefix) as one fenced json block</teammate-message>"
            Set-Content $script:Transcript @((New-Assignment), (New-Report), $wrapped, (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'recognises an assignment prefixed with the session sentence' {
            $prefixed = New-Assignment 'Another Claude session sent a message: <teammate-message teammate_id="mate">do it</teammate-message>'
            Set-Content $script:Transcript @((New-Assignment), (New-Report), $prefixed, (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }

        It 'does not count prefixed feedback as an assignment' {
            $wrapped = New-Assignment "Another Claude session sent a message: <teammate-message teammate_id=`"system`">$($script:Prefix) as one fenced json block</teammate-message>"
            Set-Content $script:Transcript @((New-Assignment), (New-Report), $wrapped, (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'accepts a report after an untagged spawn prompt' {
            Set-Content $script:Transcript @((New-Assignment 'plain spawn prompt'), (New-Report))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'treats line 0 as the assignment, so a report on line 0 does not count' {
            Set-Content $script:Transcript @((New-Report))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }
    }

    Context 'fail open' {
        It 'exits 0 when the derived transcript is missing' {
            $r = Invoke-Gate (New-Payload) $script:State
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeNullOrEmpty
        }

        It 'exits 0 when the transcript is over 5 MB' {
            $fs = [IO.File]::Create($script:Transcript)
            $fs.SetLength(6MB)
            $fs.Dispose()
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 0
        }

        It 'skips a malformed line and still gates on the rest' {
            Set-Content $script:Transcript @((New-Assignment), '{not json', (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }

        It 'exits 0 when the first entry agentId differs from agent_id' {
            $foreign = { param($Line) $Line -replace '"agentId":"a1"', '"agentId":"other"' }
            Set-Content $script:Transcript @((& $foreign (New-Assignment)), (& $foreign (New-Prose)))
            $r = Invoke-Gate (New-Payload) $script:State
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:State 'report-gate') | Should -BeFalse
        }

        It 'skips a blank first line when checking the first entry agentId' {
            Set-Content $script:Transcript @('', (New-Assignment), (New-Prose))
            (Invoke-Gate (New-Payload) $script:State).ExitCode | Should -Be 2
        }

        It 'exits 0 on unparsable stdin' {
            (Invoke-Gate 'not json at all' $script:State).ExitCode | Should -Be 0
        }

        It 'exits 0 on empty input' {
            (Invoke-Gate ' ' $script:State).ExitCode | Should -Be 0
        }

        It 'exits 0 without state when session_id is missing' {
            Set-Content $script:Transcript @((New-Assignment), (New-Prose))
            $payload = @{ agent_id = 'a1'; transcript_path = $script:Lead } | ConvertTo-Json -Compress
            $r = Invoke-Gate $payload $script:State
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:State 'report-gate') | Should -BeFalse
        }

        It 'exits 0 without state when agent_id is missing, even with teammate_name' {
            Set-Content $script:Transcript @((New-Assignment), (New-Prose))
            Set-Content (Join-Path (Split-Path $script:Transcript) 'agent-mate.jsonl') @((New-Assignment), (New-Prose))
            $payload = @{ session_id = 's1'; teammate_name = 'mate'; transcript_path = $script:Lead } | ConvertTo-Json -Compress
            $r = Invoke-Gate $payload $script:State
            $r.ExitCode | Should -Be 0
            $r.Stderr | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:State 'report-gate') | Should -BeFalse
        }

        It 'exits 0 when the state file cannot be used' {
            Set-Content $script:Transcript @((New-Assignment), (New-Prose))
            $blocker = Join-Path $TestDrive 'blocker'
            Set-Content $blocker 'a file where a directory should be'
            (Invoke-Gate (New-Payload) $blocker).ExitCode | Should -Be 0
        }
    }
}
