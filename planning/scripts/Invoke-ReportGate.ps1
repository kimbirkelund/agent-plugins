<#
.SYNOPSIS
    TeammateIdle hook: make an agent-teams teammate deliver its report before it idles.

.DESCRIPTION
    /impl teammates must report to the lead by SendMessage every turn. A teammate that ends
    its turn in prose reaches nobody, so this hook is the enforcement. It runs when a
    teammate is about to go idle and reads the teammate's own transcript (transcript_path
    in the hook payload). If no SendMessage was made since the teammate's last assignment,
    the hook writes a reminder to stderr and exits 2, which keeps the teammate working.

    An assignment is a user entry whose text starts with `<teammate-message`, other than one
    that is this hook's own feedback. Tool results never count. When the transcript holds no
    assignment, the first line (the spawn prompt) is the assignment. A report is an assistant
    entry after the last assignment with a SendMessage tool_use block. The recipient is not
    checked: a question to the lead is also a legitimate end of turn.

    Pushbacks are capped at two per teammate per session. The counter lives in
    <StateRoot>/report-gate/<session_id>.json under the key
    `<session_id>:<agent_id or teammate_name>`. A found report deletes the key. When the cap
    is reached the value becomes -1, one line is written to stdout, and the script exits 0;
    a -1 key exits 0 silently from then on. The key is never deleted on give-up, otherwise
    the next idle would start the count over.

    The hook fails open: missing or unparsable input, a payload without session_id or without
    both agent_id and teammate_name, a missing or oversized transcript, a bad transcript line
    and any state-file error all exit 0.

.PARAMETER InputJson
    Hook payload as a JSON string. Read from stdin when omitted.

.PARAMETER StateRoot
    Directory under which report-gate/ is kept. Defaults to $env:CLAUDE_PLUGIN_DATA, then
    the system temp directory.

.PARAMETER FlushDelayMs
    Wait before reading the transcript, so the last entries have reached disk. Defaults
    to 750.

.OUTPUTS
    Nothing on stdout, except one line when the pushback cap is reached. Exit 2 with the
    reminder on stderr when the teammate should keep working.
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $StateRoot,
    [int]    $FlushDelayMs = 750
)

$ErrorActionPreference = 'Stop'

$feedbackPrefix = 'Deliver your completion report to the lead via SendMessage'
$feedback = $feedbackPrefix + ' as one fenced json block with `outcome`, `files` and `evidence`, then go idle.'
$maxPushbacks = 2
$maxBytes = 5MB

function Get-EntryText
{
    param($Entry)

    $content = $Entry.message.content
    if ($content -is [string])
    {
        return $content
    }
    $texts = foreach ($block in @($content))
    {
        if ($block.type -eq 'text')
        {
            $block.text
        }
    }
    return ($texts -join "`n")
}

try
{
    if (-not $PSBoundParameters.ContainsKey('InputJson'))
    {
        $InputJson = [Console]::In.ReadToEnd()
    }
    if ([string]::IsNullOrWhiteSpace($InputJson))
    {
        exit 0
    }
    $payload = $InputJson | ConvertFrom-Json

    # Without both halves of the key, state would be shared across sessions or teammates.
    $sessionId = [string] $payload.session_id
    $member = if ($payload.agent_id) { [string] $payload.agent_id } else { [string] $payload.teammate_name }
    if (-not $sessionId -or -not $member)
    {
        exit 0
    }
    $key = "${sessionId}:$member"

    $transcript = $payload.transcript_path
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript -PathType Leaf))
    {
        exit 0
    }

    if ($FlushDelayMs -gt 0)
    {
        Start-Sleep -Milliseconds $FlushDelayMs
    }

    if ((Get-Item -LiteralPath $transcript).Length -gt $maxBytes)
    {
        exit 0
    }

    $lines = @(Get-Content -LiteralPath $transcript)
    $lastAssignment = 0
    $entries = for ($i = 0; $i -lt $lines.Count; $i++)
    {
        try
        {
            $entry = $lines[$i] | ConvertFrom-Json
        }
        catch
        {
            continue
        }
        [pscustomobject]@{ Index = $i; Entry = $entry }
    }

    foreach ($item in $entries)
    {
        if ($item.Entry.type -ne 'user')
        {
            continue
        }
        $text = (Get-EntryText $item.Entry).TrimStart()
        $body = ($text -replace '^<teammate-message(?:\s+[\w-]+="[^"]*")*\s*>', '').TrimStart()
        if ($text.StartsWith('<teammate-message') -and -not $body.StartsWith($feedbackPrefix))
        {
            $lastAssignment = $item.Index
        }
    }

    $reported = $false
    foreach ($item in $entries)
    {
        if ($item.Index -le $lastAssignment -or $item.Entry.type -ne 'assistant')
        {
            continue
        }
        foreach ($block in @($item.Entry.message.content))
        {
            if ($block.type -eq 'tool_use' -and $block.name -eq 'SendMessage')
            {
                $reported = $true
            }
        }
    }

    if (-not $StateRoot)
    {
        $StateRoot = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { [IO.Path]::GetTempPath() }
    }
    $safeSession = $sessionId -replace '[^\w.-]', '_'
    $stateFile = Join-Path $StateRoot 'report-gate' "$safeSession.json"

    $state = @{}
    if (Test-Path -LiteralPath $stateFile)
    {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
    }

    $count = if ($state.ContainsKey($key)) { [int] $state[$key] } else { 0 }
    if ($count -lt 0)
    {
        exit 0
    }

    $pushback = $false
    if ($reported)
    {
        if (-not $state.ContainsKey($key))
        {
            exit 0
        }
        $state.Remove($key)
    }
    elseif ($count -ge $maxPushbacks)
    {
        $state[$key] = -1
        Write-Output "ReportGateHook: $key idled without a delivered report"
    }
    else
    {
        $state[$key] = $count + 1
        $pushback = $true
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
    $tempFile = "$stateFile.$PID.tmp"
    try
    {
        Set-Content -LiteralPath $tempFile -Value ($state | ConvertTo-Json -Compress)
        Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
    }
    finally
    {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }

    if ($pushback)
    {
        [Console]::Error.WriteLine($feedback)
        exit 2
    }
    exit 0
}
catch
{
    exit 0
}
