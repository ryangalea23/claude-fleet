# Plan usage across all Claude Code + Codex accounts.
#
# Data comes from quota-axi (https://github.com/kunchenguid/quota-axi), which reads
# each profile's own credential file and calls the vendor's usage endpoint. That is
# free - no `claude -p /usage` turn, no scraping stale session logs - and it returns
# pace and projected-exhaustion figures the old parser had no source for.
#
# Profiles are selected the only honest way: CLAUDE_CONFIG_DIR / CODEX_HOME per run.
# A profile with no credential file is reported signed out and never run, because
# quota-axi's published build falls back to a SHARED cache and would otherwise echo
# another account's numbers as if they were this one's.
#
#   ai-usage              card grid (what a human wants)
#   ai-usage -Watch       live grid, refreshes until you press q
#   ai-usage -Watch -Every 30s
#   ai-usage -Plain       one line per profile (what a script or agent wants)
#   ai-usage -Json        merged quota figures for all profiles
#   ai-usage -ClaudeOnly / -CodexOnly / -Ascii
#   ai-usage -Force       ignore the cache and ask the vendor now
#   ai-usage -MaxAge 600  accept figures up to 10 minutes old
#   ai-usage -Heal        run `claude doctor` on a profile whose token expired (rewrites its credentials)
#   ai-usage -Demo        made-up figures from demo/fixture.json (screenshots, trying it out)
#
# Accounts come from config.json (see lib/config.ps1). With no config file, the single
# default ~/.claude + ~/.codex account is shown.

param(
    [switch]$CodexOnly,
    [switch]$ClaudeOnly,
    [switch]$Plain,
    [switch]$Cards,
    [switch]$Json,
    [switch]$Ascii,
    [switch]$Watch,
    [string]$Every = '5m',
    # Test hook: force a layout width. See the note in lib/tui.ps1.
    [int]$Width = 0,
    # Serve cached figures younger than this. These are weekly and 5-hour quotas, so
    # two minutes old is indistinguishable from live, and it keeps a dashboard (or a
    # curious agent) from earning a rate limit.
    [int]$MaxAge = 120,
    [switch]$Force,
    # When a Claude token looks expired, run `claude doctor` on that profile to refresh it.
    # Off by default: doctor rewrites the profile's credential file, and a status tool
    # should not change your login unless you ask it to.
    [switch]$Heal,
    # Accepted for older scripts that passed it. Healing is already off unless -Heal.
    [switch]$NoHeal,
    # Render made-up data from demo/fixture.json. Calls nothing and reads no credentials.
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\config.ps1"
$FleetCfg = Get-FleetConfig
$accounts = $FleetCfg.Accounts

# One renderer for both dashboards - see the note in lib/tui.ps1 about why this is not
# copied into each script.
. "$PSScriptRoot\lib\tui.ps1"
Init-Tui -Ascii:$Ascii
$C = Get-TuiColors
$G = Get-TuiGlyphs
$ESC = [char]27
$ELLIPSIS = $G.ellipsis
$MIDDOT = $G.middot

function Dir-For($base, $a) { if ($base -eq 'claude') { $a.ClaudeDir } else { $a.CodexDir } }

function Cred-For($vendor, $a) {
    if ($vendor -eq 'claude') { Join-Path (Dir-For 'claude' $a) '.credentials.json' }
    else { Join-Path (Dir-For 'codex' $a) 'auth.json' }
}

# Shared on-disk cache, one file per profile. Every caller goes through it - this script
# run by hand, dash, fleet -Usage, an agent - so no combination of them can hammer the
# endpoint. Anthropic's quota endpoint DOES rate limit: running this a handful of times
# inside a couple of minutes was enough to get "retry after" for three minutes, which is
# how this cache came to exist.
$CACHE_DIR = Join-Path $FleetCfg.StateDir 'usage-cache'

function Get-Quota($vendor, $a, [switch]$Refresh) {
    $cacheFile = Join-Path $CACHE_DIR "$vendor-$($a.Name).json"

    if (-not $Force -and -not $Refresh -and (Test-Path $cacheFile)) {
        $age = ((Get-Date) - (Get-Item $cacheFile).LastWriteTime).TotalSeconds
        if ($age -lt $MaxAge) {
            try { return (Get-Content $cacheFile -Raw | ConvertFrom-Json) } catch { }
        }
        # Past the TTL, but if the vendor told us when to come back, respect that over
        # our own schedule. Asking early just earns another refusal.
        try {
            $cached = Get-Content $cacheFile -Raw | ConvertFrom-Json
            $retry = $cached.providers[0].state.retryAfter
            if ($retry -and ([datetimeoffset]$retry) -gt (Get-Date)) { return $cached }
        } catch { }
    }

    $dir = Dir-For $vendor $a
    $env:CLAUDE_CONFIG_DIR = $null
    $env:CODEX_HOME = $null
    if ($vendor -eq 'claude') { $env:CLAUDE_CONFIG_DIR = $dir } else { $env:CODEX_HOME = $dir }
    try {
        $raw = & quota-axi --provider $vendor --full --json --no-credential-refresh 2>&1
        $json = ($raw -join "`n" | ConvertFrom-Json)
        if ($json) {
            New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
            # Write then move: a reader must never catch a half-written cache.
            $tmp = "$cacheFile.tmp"
            ($raw -join "`n") | Set-Content -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $cacheFile -Force
        }
        return $json
    } catch {
        return $null
    } finally {
        $env:CLAUDE_CONFIG_DIR = $null
        $env:CODEX_HOME = $null
    }
}

# --- shaping -----------------------------------------------------------------

function Format-Dur($iso) {
    # A missing resetsAt is not an unknown, it is "no cycle running". An unused 5-hour
    # window has not started yet, and extra usage is a balance with no window at all.
    # Reserve '?' for a value we genuinely could not read.
    if (-not $iso) { return '-' }
    try { $t = ([datetimeoffset]$iso).LocalDateTime } catch { return '?' }
    $s = $t - (Get-Date)
    if ($s.TotalMinutes -lt 1) { return 'now' }
    if ($s.TotalDays -ge 1) { return '{0}d {1}h' -f [Math]::Floor($s.TotalDays), $s.Hours }
    if ($s.TotalHours -ge 1) { return '{0}h {1}m' -f [Math]::Floor($s.TotalHours), $s.Minutes }
    return '{0}m' -f [int]$s.TotalMinutes
}

function Format-Span($secs) {
    $sp = [timespan]::FromSeconds([double]$secs)
    if ($sp.TotalDays -ge 1) { return '{0}d {1}h' -f [Math]::Floor($sp.TotalDays), $sp.Hours }
    if ($sp.TotalHours -ge 1) { return '{0}h {1}m' -f [Math]::Floor($sp.TotalHours), $sp.Minutes }
    return '{0}m' -f [int]$sp.TotalMinutes
}

function Format-Runway($ea) {
    if (-not $ea -or -not $ea.runway) { return $null }
    switch ($ea.runway.status) {
        'through_reset' { return @{ text = "on pace $($G.ok)"; color = $C.green } }
        'exhausted_now' { return @{ text = 'empty now'; color = $C.red } }
        'projected_exhaustion' {
            if ($null -eq $ea.runway.usableRunwaySeconds) { return @{ text = 'burning fast'; color = $C.yellow } }
            return @{ text = "empty in $(Format-Span $ea.runway.usableRunwaySeconds)"; color = $C.yellow }
        }
    }
    return $null
}

# Vendor labels are written for a wide dashboard; the label column is 9 chars.
# Map the ones we know rather than truncating them into mush ("Fable we.").
function Short-Label($label) {
    switch -Regex ($label) {
        '^session$' { return 'session' }
        '^week$' { return 'week' }
        '^Fable week$' { return 'fable' }
        '^Opus week$' { return 'opus' }
        '^extra usage$' { return 'extra' }
        'Spark session$' { return 'spark 5h' }
        'Spark week$' { return 'spark wk' }
        '^gpt-reserve week$' { return 'reserve' }
    }
    return ($label -replace ' week$', '' -replace ' session$', ' 5h')
}

function Read-Profile($vendor, $a) {
    $o = [ordered]@{
        Vendor = $vendor; Account = $a.Name; Status = 'signedout'; Plan = ''; Source = ''
        HeadPct = $null; HeadLabel = ''; HeadFull = ''; Runway = $null; Windows = @(); RetryAt = $null
    }
    if (-not (Test-Path (Cred-For $vendor $a))) { return [pscustomobject]$o }

    $j = Get-Quota $vendor $a
    $p = if ($j) { $j.providers | Select-Object -First 1 } else { $null }
    if (-not $p) { $o.Status = 'error'; return [pscustomobject]$o }

    # An expired access token reports "Claude sign-in required" even though the profile IS
    # logged in and holds a refresh token. quota-axi will not exchange a Claude refresh
    # token itself (Anthropic rotates it on use, which would sign Claude Code out), so the
    # account silently goes dark - exactly what happens to an account you are not using,
    # which is the one you most need a number for. `claude doctor` is the vendor's own
    # health check: it starts no session and spends no quota, and it does refresh the
    # token. Measured: an account expired 684 minutes came back valid for 480.
    if ($vendor -eq 'claude' -and $p.state.status -eq 'auth_required' -and $Heal -and -not $NoHeal) {
        $dir = Dir-For 'claude' $a
        $prev = $env:CLAUDE_CONFIG_DIR
        try {
            $env:CLAUDE_CONFIG_DIR = $dir
            & claude doctor *> $null
        } catch { } finally {
            if ($prev) { $env:CLAUDE_CONFIG_DIR = $prev } else { $env:CLAUDE_CONFIG_DIR = $null }
        }
        $j = Get-Quota $vendor $a -Refresh
        $p = if ($j) { $j.providers | Select-Object -First 1 } else { $p }
    }

    $o.Plan = $p.plan
    $o.Source = $p.source
    # The quota endpoint rate limits if you ask too often - easy to hit with a live
    # dashboard, or just by running this a few times in a row. It is not "unknown", it is
    # "ask again at X", and saying so stops it looking like the tool is broken.
    $o.Status = if ($p.state.status -eq 'rate_limited') { 'ratelimited' }
                elseif ($p.state.status -eq 'auth_required') { 'authrequired' }
                elseif ($p.state.stale) { 'stale' }
                else { 'ok' }
    $o.RetryAt = $p.state.retryAfter

    $ea = $p.quotaSemantics.effectiveAvailability | Where-Object { $_.scope -eq 'all_models' } | Select-Object -First 1
    if ($ea) {
        $o.HeadPct = $ea.effectivePercentRemaining
        $labels = foreach ($id in @($ea.limitingWindowIds)) {
            ($p.windows | Where-Object { $_.id -eq $id } | Select-Object -First 1).label
        }
        $kept = @($labels | Where-Object { $_ })
        $o.HeadFull = ($kept -join ' + ')
        $o.HeadLabel = (@($kept | ForEach-Object { Short-Label $_ }) -join ' + ')
        if (-not $o.HeadLabel) { $o.HeadLabel = 'all models' }
        $o.Runway = Format-Runway $ea
    }
    $o.Windows = foreach ($w in $p.windows) {
        [pscustomobject]@{
            Label  = Short-Label $w.label
            Full   = $w.label
            Pct    = $w.percentRemaining
            Reset  = Format-Dur $w.resetsAt
            # The marker sits at "spent perfectly linearly", so bar past marker = under pace.
            Marker = if ($null -ne $w.pace -and $null -ne $w.pace.timeRemainingPercent) { [double]$w.pace.timeRemainingPercent } else { $null }
        }
    }
    return [pscustomobject]$o
}

# --- rendering ---------------------------------------------------------------

function Render-Card($e, $inner) {
    $lines = @()
    # The dot carries the card's status at a glance, so color it by headroom.
    $dotColor = switch ($e.Status) {
        'signedout' { $C.grey }
        'error' { $C.grey }
        default { Pct-Color $e.HeadPct }
    }
    $head = "$dotColor$($G.dot)$($C.reset) $($C.bold)$($e.Vendor)$($C.reset) $($C.grey)$MIDDOT$($C.reset) $($e.Account)"
    $right = switch ($e.Status) {
        'signedout' { "$($C.grey)signed out$($C.reset)" }
        'error' { "$($C.red)unavailable$($C.reset)" }
        'ratelimited' { "$($C.yellow)rate limited$($C.reset)" }
        'authrequired' { "$($C.yellow)sign-in expired$($C.reset)" }
        default { "$($C.grey)$($e.Plan) $MIDDOT $($e.Source)$($C.reset)" }
    }
    $gap = [Math]::Max(1, $inner - (Vis-Len $head) - (Vis-Len $right))
    $lines += $head + (' ' * $gap) + $right

    if ($e.Status -eq 'signedout') {
        $lines += ''
        $lines += "$($C.grey)no credential file for this profile$($C.reset)"
        $lines += "$($C.grey)excluded from totals$($C.reset)"
        return $lines
    }
    if ($e.Status -eq 'authrequired') {
        $lines += ''
        $lines += "$($C.grey)the access token expired$($C.reset)"
        $lines += "$($C.grey)run claude doctor, or ai-usage -Heal$($C.reset)"
        return $lines
    }
    if ($e.Status -eq 'ratelimited') {
        $lines += ''
        $lines += "$($C.grey)the quota endpoint is rate limiting$($C.reset)"
        $lines += "$($C.grey)retry $(Format-Dur $e.RetryAt)$($C.reset)"
        return $lines
    }
    if ($e.Status -eq 'error') {
        $lines += ''
        $lines += "$($C.grey)quota-axi returned no provider report$($C.reset)"
        return $lines
    }

    $lines += ''
    $pc = Pct-Color $e.HeadPct
    $hl = "$pc$($C.bold)$($e.HeadPct)%$($C.reset) $($e.HeadLabel)"
    $rw = if ($e.Status -eq 'stale') { "$($C.yellow)stale$($C.reset)" }
          elseif ($e.Runway) { "$($e.Runway.color)$($e.Runway.text)$($C.reset)" }
          else { '' }
    $gap = [Math]::Max(1, $inner - (Vis-Len $hl) - (Vis-Len $rw))
    $lines += $hl + (' ' * $gap) + $rw

    $hw = $e.Windows | Where-Object { $_.Full -eq $e.HeadFull } | Select-Object -First 1
    $lines += Render-Bar $e.HeadPct $(if ($hw) { $hw.Marker } else { $null }) $inner $pc
    $lines += ''

    # label(9) space bar space pct(4) space reset(8)
    $barW = $inner - 9 - 1 - 1 - 4 - 1 - 8
    foreach ($w in $e.Windows) {
        $lab = Pad-To (Fit $w.Label 9) 9
        $bar = Render-Bar $w.Pct $w.Marker $barW (Pct-Color $w.Pct)
        $pct = if ($null -ne $w.Pct) { '{0,3}%' -f [int]$w.Pct } else { '  ?%' }
        $lines += "$($C.grey)$lab$($C.reset) $bar $(Pct-Color $w.Pct)$pct$($C.reset) $($C.grey)$('{0,8}' -f $w.Reset)$($C.reset)"
    }
    return $lines
}

function Render-Grid($entries) {
    $width = try { [Console]::WindowWidth } catch { 120 }
    if ($width -lt 40) { $width = 120 }
    $twoUp = $width -ge 112
    $inner = if ($twoUp) { [Math]::Min(52, [int](($width - 8) / 2)) } else { [Math]::Min(64, $width - 6) }

    $live = @($entries | Where-Object { $_.Status -in 'ok', 'stale' }).Count
    $out = @($entries | Where-Object { $_.Status -eq 'signedout' }).Count
    $bad = @($entries | Where-Object { $_.Status -eq 'error' }).Count
    $hdr = "$($C.bold)ai-usage$($C.reset) $($C.grey)$MIDDOT$($C.reset) $(Get-Date -Format 'yyyy-MM-dd HH:mm') $($C.grey)$MIDDOT$($C.reset) $live live"
    if ($out) { $hdr += " $($C.grey)$MIDDOT$($C.reset) $out signed out" }
    if ($bad) { $hdr += " $($C.grey)$MIDDOT$($C.reset) $bad unavailable" }
    ''
    $hdr
    "$($C.grey)bars show headroom left $MIDDOT $($G.mark) marks linear pace $MIDDOT past the mark = spending slower than the clock$($C.reset)"
    ''

    $cards = @(foreach ($e in $entries) { , (Build-Card (Render-Card $e $inner) $inner) })
    if (-not $twoUp) {
        foreach ($c in $cards) { $c; '' }
        return
    }
    for ($i = 0; $i -lt $cards.Count; $i += 2) {
        $l = $cards[$i]
        $r = if ($i + 1 -lt $cards.Count) { $cards[$i + 1] } else { $null }
        $h = if ($r) { [Math]::Max($l.Count, $r.Count) } else { $l.Count }
        for ($n = 0; $n -lt $h; $n++) {
            $ll = if ($n -lt $l.Count) { $l[$n] } else { '' }
            if (-not $r) { Pad-To $ll ($inner + 4); continue }
            $rr = if ($n -lt $r.Count) { $r[$n] } else { '' }
            (Pad-To $ll ($inner + 4)) + '  ' + $rr
        }
        ''
    }
}

function Render-Plain($entries) {
    foreach ($e in $entries) {
        $head = '{0,-6} {1,-9}' -f $e.Vendor, $e.Account
        if ($e.Status -eq 'signedout') { "$head not logged in"; continue }
        if ($e.Status -eq 'error') { "$head unavailable"; continue }
        if ($e.Status -eq 'ratelimited') { "$head rate limited by the quota endpoint$(if ($e.RetryAt) { ' - retry ' + (Format-Dur $e.RetryAt) })"; continue }
        if ($e.Status -eq 'authrequired') { "$head sign-in expired - run: CLAUDE_CONFIG_DIR=$(Dir-For 'claude' (Get-FleetAccount $FleetCfg $e.Account)) claude doctor (or ai-usage -Heal)"; continue }
        $w = ($e.Windows | ForEach-Object { '{0} {1}% ({2})' -f $_.Label, [int]$_.Pct, $_.Reset }) -join ' | '
        $rw = if ($e.Runway) { " [$($e.Runway.text)]" } else { '' }
        $st = if ($e.Status -eq 'stale') { ' [STALE]' } else { '' }
        # Every percentage here is headroom LEFT, not usage spent. Say so on the line,
        # because the two read identically and the wrong reading inverts every decision.
        # A null headline is a real state (stale data, no windows reported). Printing
        # "% left on" with nothing in front of it reads as a broken tool.
        $headline = if ($null -ne $e.HeadPct) { '{0}% left on {1}' -f $e.HeadPct, $e.HeadLabel } else { 'no headline figure' }
        '{0} {1,-7} {2} | {3}{4}{5}' -f $head, $e.Plan, $headline, $w, $rw, $st
    }
}

# --- main --------------------------------------------------------------------

if (-not $Demo -and -not (Get-Command quota-axi -ErrorAction SilentlyContinue)) {
    Write-Error 'quota-axi not found. Install it with: npm install -g quota-axi'
    exit 1
}

$vendors = @()
if (-not $CodexOnly) { $vendors += 'claude' }
if (-not $ClaudeOnly) { $vendors += 'codex' }

# Demo entries have the same shape Read-Profile returns, so every renderer below runs
# unchanged. Times are stored as minutes from now, so the demo never looks stale.
function Get-DemoEntries {
    $fx = Get-Content (Join-Path $PSScriptRoot 'demo\fixture.json') -Raw | ConvertFrom-Json
    $now = [datetimeoffset]::Now
    foreach ($u in @($fx.usage | Where-Object { $_.vendor -in $vendors })) {
        $runway = if ($u.runway) {
            $col = switch ($u.runway.tone) { 'ok' { $C.green } 'bad' { $C.red } default { $C.yellow } }
            $txt = $u.runway.text -replace '\{ok\}', $G.ok
            @{ text = $txt; color = $col }
        } else { $null }
        [pscustomobject]@{
            Vendor = $u.vendor; Account = $u.account; Status = $u.status; Plan = $u.plan; Source = $u.source
            HeadPct = $u.headPct; HeadLabel = $u.headLabel; HeadFull = $u.headFull; Runway = $runway
            RetryAt = if ($null -ne $u.retryInMinutes) { $now.AddMinutes($u.retryInMinutes).ToString('o') } else { $null }
            Windows = @(foreach ($w in @($u.windows)) {
                [pscustomobject]@{
                    Label  = $w.label
                    Full   = $w.full
                    Pct    = $w.pct
                    Reset  = if ($null -ne $w.resetInMinutes) { Format-Dur ($now.AddMinutes($w.resetInMinutes + 0.5).ToString('o')) } else { '-' }
                    Marker = $w.marker
                }
            })
        }
    }
}

function Get-Entries {
    if ($Demo) { return @(Get-DemoEntries) }
    @(foreach ($v in $vendors) { foreach ($a in $accounts) { Read-Profile $v $a } })
}

function Parse-Every($s) {
    if ($s -notmatch '^\s*(\d+)\s*([smh])\s*$') { throw "-Every wants something like 30s, 5m, or 1h (got '$s')" }
    $n = [int]$Matches[1]
    $secs = switch ($Matches[2]) { 's' { $n } 'm' { $n * 60 } 'h' { $n * 3600 } }
    if ($secs -lt 30) { throw '-Every must be at least 30s; these are live API calls' }
    if ($secs -gt 86400) { throw '-Every must be 24h or less' }
    return $secs
}

if ($Watch) {
    $secs = Parse-Every $Every
    # Without a real terminal there is no q to press and no screen to restore, so the
    # loop would run forever inside whatever captured it. Refuse instead of hanging.
    if ([Console]::IsOutputRedirected) {
        Write-Error '-Watch needs a real terminal. For piped or scripted output use -Plain or -Json.'
        exit 1
    }
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }
    # Alternate screen: the live view owns the screen and hands it back untouched on quit.
    Write-Host -NoNewline "$ESC[?1049h$ESC[?25l"
    $last = ''
    try {
        while ($true) {
            $text = (Render-Grid (Get-Entries)) -join "`n"
            $last = $text
            $quit = if ($canPoll) { 'press q to quit' } else { 'press Ctrl+C to quit' }
            $foot = "$($C.grey)refreshes every $Every $MIDDOT updated $(Get-Date -Format 'HH:mm:ss') $MIDDOT $quit$($C.reset)"
            Write-Host -NoNewline "$ESC[H$ESC[2J"
            Write-Host $text
            Write-Host $foot
            $until = (Get-Date).AddSeconds($secs)
            while ((Get-Date) -lt $until) {
                if ($canPoll -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q' -or ($k.Modifiers -band [ConsoleModifiers]::Control -and $k.Key -eq 'C')) { return }
                    # Any other key redraws now.
                    break
                }
                Start-Sleep -Milliseconds 200
            }
        }
    } finally {
        Write-Host -NoNewline "$ESC[?25h$ESC[?1049l"
        # Echo the frame we already have so the report stays in scrollback. Re-reading
        # here would cost another round of API calls just to print what we just drew.
        if ($last) { $last }
    }
    exit 0
}

$entries = Get-Entries

if ($Json) {
    # RetryAt is here so dash can say when a rate-limited account can be asked again.
    $entries | Select-Object Vendor, Account, Status, Plan, HeadPct, HeadLabel, Windows, RetryAt,
        @{ n = 'Runway'; e = { if ($_.Runway) { $_.Runway.text } else { $null } } } | ConvertTo-Json -Depth 6
    exit 0
}

# A redirected stdout is a script or an agent reading this, not a person looking at cards.
# -Cards forces the grid anyway, which is what you want when piping to a file or a screenshot.
if ($Cards) { Render-Grid $entries }
elseif ($Plain -or [Console]::IsOutputRedirected) { Render-Plain $entries }
else { Render-Grid $entries }
