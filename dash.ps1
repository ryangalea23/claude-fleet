# dash - one pane, both dashboards: plan usage on top, running agents below.
#
# The point is a single terminal tab instead of two: usage barely changes minute to
# minute (it is a weekly/5-hour quota), fleet activity changes every few seconds. So
# usage is fetched on its own slow cycle and fleet is fetched on the fast -Every tick,
# and both share the one renderer in lib/tui.ps1 so the two blocks look like one tool.
#
#   dash              one snapshot
#   dash -Watch       refreshes fleet every -Every (default 2m), usage every 15m
#   dash -Hours 12    widen the Codex window (passed through to fleet.ps1)
#   dash -Ascii       no colour/unicode - screenshots, non-UTF8 consoles
#   dash -Once        force a single frame even if -Watch is also passed
#   dash -Demo        made-up usage and sessions from demo/fixture.json
#   dash -Demo -Watch the same, played as a short story that refreshes every second

param(
    [switch]$Watch,
    [switch]$Once,
    [string]$Every = '120s',
    [switch]$Ascii,
    [int]$Hours = 6,
    # Override the console width. Only for testing that the layout holds at 80 or 160
    # columns, which cannot be done otherwise since WindowWidth is not settable.
    [int]$Width = 0,
    # Render made-up data from demo/fixture.json instead of reading this machine.
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\tui.ps1"
Init-Tui -Ascii:$Ascii
$C = Get-TuiColors
$G = Get-TuiGlyphs
$ESC = [char]27

# Same contract as ai-usage.ps1's -Every: a lower bound because usage is a real API call
# (fleet reads local files, so it is cheap, but the two share one -Every for one screen),
# an upper bound because a dashboard that never refreshes is a bug, not a feature.
function Parse-Every($s) {
    if ($s -notmatch '^\s*(\d+)\s*([smh])\s*$') { throw "-Every wants something like 30s, 5m, or 1h (got '$s')" }
    $n = [int]$Matches[1]
    $secs = switch ($Matches[2]) { 's' { $n } 'm' { $n * 60 } 'h' { $n * 3600 } }
    if ($secs -lt 30) { throw '-Every must be at least 30s' }
    if ($secs -gt 86400) { throw '-Every must be 24h or less' }
    return $secs
}

# --- usage (slow cycle - real API calls, cached 5 minutes) -------------------

$script:UsageEntries = $null
$script:UsageFetchedAt = $null
$USAGE_TTL_SECS = 900
# Which step of the demo story to draw. Advanced once per -Watch frame.
$script:DemoTick = 0

function Get-UsageEntries {
    param([switch]$Force)
    $stale = -not $script:UsageEntries -or -not $script:UsageFetchedAt -or
             ((Get-Date) - $script:UsageFetchedAt).TotalSeconds -gt $USAGE_TTL_SECS
    # Demo figures cost nothing to read and change every step, so never cache them.
    if ($Force -or $stale -or $Demo) {
        $raw = & "$PSScriptRoot\ai-usage.ps1" -Json -Demo:$Demo -DemoTick $script:DemoTick
        try {
            $j = ($raw -join "`n" | ConvertFrom-Json)
            $script:UsageEntries = @($j)
        } catch {
            $script:UsageEntries = @()
        }
        $script:UsageFetchedAt = Get-Date
    }
    return $script:UsageEntries
}

function Format-Age($since) {
    if (-not $since) { return '?' }
    $s = ((Get-Date) - $since).TotalSeconds
    if ($s -lt 60) { return "{0}s" -f [int]$s }
    if ($s -lt 3600) { return "{0}m" -f [int]($s / 60) }
    return "{0}h" -f [int]($s / 3600)
}

function Render-UsageLine($e, $barW) {
    $lab = Pad-To ("{0} {1}" -f $e.Vendor, $e.Account) 16
    if ($e.Status -eq 'signedout') { return "$($C.grey)$lab signed out$($C.reset)" }
    if ($e.Status -eq 'error') { return "$($C.grey)$lab$($C.reset) $($C.red)unavailable$($C.reset)" }
    # An empty bar reading "?%" looks like the dashboard is broken. It is not: the quota
    # endpoint rate limits, and the honest answer is when to ask again.
    if ($e.Status -eq 'ratelimited') {
        $when = if ($e.RetryAt) { try { ([datetimeoffset]$e.RetryAt).LocalDateTime.ToString('HH:mm:ss') } catch { '?' } } else { '?' }
        return "$($C.grey)$lab$($C.reset) $($C.yellow)rate limited$($C.reset) $($C.grey)retry $when$($C.reset)"
    }

    $pc = Pct-Color $e.HeadPct
    $bar = Render-Bar $e.HeadPct $null $barW $pc
    $pctTxt = if ($null -ne $e.HeadPct) { '{0,3}%' -f [int]$e.HeadPct } else { '  ?%' }

    $tail = @()
    if ($e.HeadLabel) { $tail += $e.HeadLabel }
    if ($e.Status -eq 'stale') { $tail += "$($C.yellow)stale$($C.reset)" }
    elseif ($e.Runway) { $tail += "$($C.grey)$($e.Runway)$($C.reset)" }

    "$lab $bar $pc$pctTxt$($C.reset) $($tail -join ' ')"
}

# --- fleet (fast cycle - local files only) ------------------------------------

function Get-FleetLines {
    # -Width must go down to the child too. Without it the child measures the real console
    # and renders 114-wide cards under an 80-wide usage block, which wraps and shears the
    # whole panel. Found by testing at 80 columns; it is invisible at the default width.
    # -Rows, not -Cards: dash shares one pane with the usage block, and a five-line card
    # per session pushes the fleet off the screen at six sessions. -Cards is still right
    # when fleet has a whole tab to itself.
    & "$PSScriptRoot\fleet.ps1" -Compact -Hours $Hours -Ascii:$Ascii -Width $Width -Demo:$Demo -DemoTick $script:DemoTick
}

# --- assembly ------------------------------------------------------------------

# Every rendered line comes back the same visible width: pad to the widest line in the
# frame rather than a fixed column count, so 80/120/160-column terminals all line up
# without wrapping or misaligning the right edge of the fleet cards below the bars above.
function Render-Dash {
    $lay = Get-Layout -Width $Width
    $usage = Get-UsageEntries
    $fleetLines = @(Get-FleetLines)

    $barW = if ($lay.Width -ge 100) { 24 } else { 14 }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$($C.bold)dash$($C.reset) $($C.grey)$($G.middot)$($C.reset) $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')
    $lines.Add("$($C.grey)USAGE $($G.middot) figures $(Format-Age $script:UsageFetchedAt) old$($C.reset)")
    foreach ($e in $usage) { $lines.Add((Render-UsageLine $e $barW)) }
    $lines.Add('')
    foreach ($fl in $fleetLines) { $lines.Add($fl) }

    $w = ($lines | ForEach-Object { Vis-Len $_ } | Measure-Object -Maximum).Maximum
    return @($lines | ForEach-Object { Pad-To $_ $w })
}

# --- main ----------------------------------------------------------------------

$secs = Parse-Every $Every
# The demo reads a fixture, not the machine, so it plays at one step a second.
if ($Demo -and -not $PSBoundParameters.ContainsKey('Every')) { $secs = 1; $Every = '1s' }
$runOnce = $Once -or -not $Watch

if (-not $runOnce) {
    # Same reason ai-usage.ps1 refuses: without a real console there is no q to press
    # and no alternate screen to hand back, so the loop would spin forever in a pipe.
    if ([Console]::IsOutputRedirected) {
        Write-Error '-Watch needs a real terminal. For a single frame use dash (no -Watch), or dash -Once.'
        exit 1
    }
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }

    Get-UsageEntries -Force | Out-Null
    Write-Host -NoNewline "$ESC[?1049h$ESC[?25l"
    $last = ''
    try {
        while ($true) {
            $text = (Render-Dash) -join "`n"
            $last = $text
            $quit = if ($canPoll) { 'press q to quit' } else { 'press Ctrl+C to quit' }
            $usageEvery = if ($Demo) { $Every } else { '15m' }
            $foot = "$($C.grey)fleet refreshes every $Every $($G.middot) usage every $usageEvery $($G.middot) updated $(Get-Date -Format 'HH:mm:ss') $($G.middot) $quit$($C.reset)"
            # One write that homes the cursor and overwrites in place, clearing each line's tail
            # and whatever is left below. Clearing the screen first shows a blank frame between
            # refreshes, which is visible as flicker.
            Write-Host -NoNewline ("$ESC[H" + (($text -split "`n") -join "$ESC[K`n") + "$ESC[K`n$foot$ESC[K$ESC[J")
            if ($Demo) { $script:DemoTick++ }
            $until = (Get-Date).AddSeconds($secs)
            while ((Get-Date) -lt $until) {
                if ($canPoll -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q' -or ($k.Modifiers -band [ConsoleModifiers]::Control -and $k.Key -eq 'C')) { return }
                    break
                }
                Start-Sleep -Milliseconds 200
            }
        }
    } finally {
        Write-Host -NoNewline "$ESC[?25h$ESC[?1049l"
        if ($last) { $last }
    }
    exit 0
}

Get-UsageEntries -Force | Out-Null
Render-Dash
