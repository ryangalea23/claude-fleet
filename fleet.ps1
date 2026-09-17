# fleet - what every local agent is doing, across both CLIs and all accounts.
#
# Read-only and out-of-band: every byte here was already written by the agents
# themselves, so watching costs them nothing.
#
#   fleet            one snapshot
#   fleet -Watch     refresh every 10s
#   fleet -Hours 12  widen the Codex window (default 6h)
#   fleet -Usage     also show plan usage (calls ai-usage; free, reads vendor usage APIs)
#   fleet -Full      don't truncate the "doing" column
#   fleet -Plain     dense rows (the default when output is piped)
#   fleet -Compact   one coloured line per session
#   fleet -Demo      made-up sessions from demo/fixture.json (screenshots, trying it out)
#   fleet -Demo -Watch   the same, played as a short story that refreshes every second
#
# Accounts come from config.json (see lib/config.ps1). The richest view needs the state
# hook in hooks/fleet-hook.js wired into Claude Code and Codex; without it, fleet falls
# back to reading the transcripts, which still works.

param([switch]$Watch, [int]$Hours = 6, [switch]$Usage, [switch]$Full, [switch]$Approx, [switch]$Detail, [switch]$All, [int]$Every = 10,
      [switch]$Plain, [switch]$Cards, [switch]$Ascii, [switch]$Compact,
      # Test hook: force a layout width. WindowWidth is not settable, so without this
      # there is no way to prove the cards still line up at 80 or 160 columns.
      [int]$Width = 0,
      # Render made-up sessions from demo/fixture.json instead of reading this machine.
      [switch]$Demo,
      # Which step of the demo story to draw. -Watch advances it; dash passes its own.
      [int]$DemoTick = 0)

# Cards for a person, rows for a script. A redirected stdout is an agent or a pipeline
# reading this, and it wants the dense text, same rule as ai-usage.
. "$PSScriptRoot\lib\tui.ps1"
. "$PSScriptRoot\lib\config.ps1"
. "$PSScriptRoot\lib\demo.ps1"
Init-Tui -Ascii:$Ascii
$UseCards = $Cards -or (-not $Plain -and -not [Console]::IsOutputRedirected)

$FleetCfg = Get-FleetConfig
$accounts = $FleetCfg.Accounts

# Logs reach hundreds of MB with single lines in the megabytes; Get-Content -Tail on those
# runs for minutes. Seek the last chunk of bytes instead (shared open - still being written).
function Get-TailLines($path, $bytes = 262144) {
    try { $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite') } catch { return @() }
    try {
        $start = [Math]::Max(0, $fs.Length - $bytes)
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        $read = $fs.Read($buf, 0, $buf.Length)
        ([Text.Encoding]::UTF8.GetString($buf, 0, $read) -split "`n") | Select-Object -Skip 1
    } finally { $fs.Dispose() }
}

function Trunc($s, $n) {
    if (-not $s) { return '' }
    # Strip control characters (see Clean-Text in lib/tui.ps1), box-drawing and block
    # characters, and runs of ASCII banner art - pasted banners otherwise render as a row of
    # garbage. Other non-ASCII text (accents, CJK, symbols) is kept.
    $s = ((Clean-Text $s) -replace '[\u2500-\u259F]', ' ') -replace '[-=_*#~|]{3,}', ' '
    $s = ($s -replace '\s+', ' ').Trim()
    if (-not $s) { return '' }
    if ($Full -or $s.Length -le $n) { $s } else { $s.Substring(0, $n - 1) + '.' }
}

# The interesting state is not busy/idle, it's: what was it asked, what is it doing now,
# and did the turn end (= waiting on you) or is it mid-work.
function Get-Worktree($tailLines) {
    # Every line carries the cwd Claude Code recorded. Agents cd around (into memory dirs,
    # temp, etc), so take the most common worktree-shaped cwd, not the last one.
    $cwds = $tailLines | Select-String -Pattern '"cwd":"([^"]+)"' -AllMatches |
            ForEach-Object { $_.Matches } | ForEach-Object { ($_.Groups[1].Value -replace '\\', '\') }
    if (-not $cwds) { return $null }
    $wt = $cwds | Where-Object { $_ -match '(?:[\w.-]+-agents|\.worktrees)[\/]([\w.-]+)' } |
          ForEach-Object { if ($_ -match '(?:[\w.-]+-agents|\.worktrees)[\/]([\w.-]+)') { $Matches[1] } } |
          Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    if ($wt) { return $wt.Name }
    # Ignore housekeeping dirs an agent cd's into (memory, config, temp) - they are never
    # what the session is working on.
    $skip = '*\.claude*', '*\.codex*', '*\memory*', '*appdata*', '*\temp*', '*\.git*'
    $real = $cwds | Where-Object { $c = $_.ToLower(); -not ($skip | Where-Object { $c -like $_ }) }
    if (-not $real) { $real = $cwds }
    $common = $real | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
    Split-Path $common.Name -Leaf
}

function Get-FirstAsk($logPath) {
    # The terminal tab title is the session's first prompt; read it from the file head.
    try { $fs = [IO.File]::Open($logPath,'Open','Read','ReadWrite') } catch { return $null }
    try {
        $buf = New-Object byte[] ([Math]::Min(300000, $fs.Length))
        $n = $fs.Read($buf, 0, $buf.Length)
        foreach ($line in ([Text.Encoding]::UTF8.GetString($buf,0,$n) -split "`n")) {
            if ($line -notmatch '"role":"user"') { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ($o.isMeta) { continue }
            $c = $o.message.content
            $t = if ($c -is [string]) { $c } else { ($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
            if ($t -and $t.Trim() -and $t -notmatch '^<') { return $t }
        }
    } finally { $fs.Dispose() }
    $null
}

function Get-Activity($logPath) {
    $lastAsk = $null; $lastTool = $null; $lastSay = $null; $endedWithText = $false; $stamp = $null
    $tailLines = Get-TailLines $logPath
    foreach ($line in $tailLines) {
        if ($line -notmatch '^\{') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $m = $o.message; if (-not $m) { continue }
        $text = ''; $tools = @()
        if ($m.content -is [string]) { $text = $m.content }
        elseif ($m.content) {
            foreach ($b in $m.content) {
                switch ($b.type) {
                    'text'        { $text += $b.text }
                    'tool_use'    { $tools += $b.name }
                    'tool_result' { $text += '' }
                }
            }
        }
        if ($o.timestamp) { $stamp = $o.timestamp }
        if ($m.role -eq 'user' -and $text.Trim() -and -not $o.isMeta) { $lastAsk = $text; $endedWithText = $false }
        if ($m.role -eq 'assistant') {
            if ($tools.Count) { $lastTool = $tools[-1]; $endedWithText = $false }
            elseif ($text.Trim()) { $lastSay = $text; $endedWithText = $true }
        }
    }
    [pscustomobject]@{
        Ask      = $lastAsk
        Doing    = if ($endedWithText) { $lastSay } else { $lastTool }
        Waiting  = $endedWithText
        Stamp    = $stamp
        Worktree = Get-Worktree $tailLines
    }
}

function Normalize-Path($p) {
    $p = $p -replace '\\', '\'
    if ($p -match '^/([a-zA-Z])/')      { $p = $Matches[1] + ':' + $p.Substring(2) }
    elseif ($p -match '^/Users/')        { $p = 'C:' + $p }
    ($p -replace '/', '\')
}
function Span($ts) {
    if ($null -eq $ts) { return '  ?' }
    $m = [int]((Get-Date) - $ts).TotalMinutes
    if ($m -lt 60)   { return "{0}m" -f $m }
    if ($m -lt 1440) { return "{0}h" -f [int]($m / 60) }
    "{0}d" -f [int]($m / 1440)
}

$script:BranchCache = @{}
function Get-Branch($path) {
    # A real lookup, not a guess from the path. Cached per folder because several sessions
    # share one, and this runs on every dashboard tick.
    if (-not $path) { return $null }
    if ($script:BranchCache.ContainsKey($path)) { return $script:BranchCache[$path] }
    $b = $null
    if (Test-Path $path) {
        try {
            # 2>$null is not enough: a non-repo makes git exit 128, and with
            # $ErrorActionPreference high that becomes a terminating error mid-loop.
            $b = & git -C $path rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -ne 0) { $b = $null }
        } catch { $b = $null }
    }
    # main/master tells you nothing - every default-branch session looks alike.
    if ($b -in @('main', 'master', 'HEAD')) { $b = $null }
    $script:BranchCache[$path] = $b
    return $b
}

function Get-CodexInfo($path) {
    # Codex rollouts carry the same substance as Claude transcripts, in a different schema:
    # session_meta (cwd + session id), payload.message (role/content), function_call /
    # custom_tool_call (tool name), task_complete (turn ended).
    $info = [pscustomobject]@{ Cwd = $null; SessionId = $null; Chat = $null; Ask = $null; Doing = $null; Waiting = $false }
    try { $head = Get-Content $path -TotalCount 60 } catch { return $info }
    foreach ($line in $head) {
        if ($line -notmatch '^\{') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -eq 'session_meta' -or $o.payload.type -eq 'session_meta') {
            $info.Cwd = $o.payload.cwd
            $info.SessionId = $o.payload.session_id
        }
        if (-not $info.Chat -and $o.payload.type -eq 'message' -and $o.payload.role -eq 'user') {
            $t = ($o.payload.content | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ' '
            if ($t -and $t -notmatch '^<') { $info.Chat = $t }
        }
    }
    foreach ($line in (Get-TailLines $path)) {
        if ($line -notmatch '^\{') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        $pl = $o.payload
        switch ($pl.type) {
            'message' {
                $t = ($pl.content | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ' '
                if ($pl.role -eq 'user' -and $t -and $t -notmatch '^<') { $info.Ask = $t; $info.Waiting = $false }
                elseif ($pl.role -eq 'assistant' -and $t) { $info.Doing = $t }
            }
            'agent_message'     { $t = ($pl.content | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ' '; if ($t) { $info.Doing = $t } }
            'function_call'     { $info.Doing = $pl.name; $info.Waiting = $false }
            'custom_tool_call'  { $info.Doing = $pl.name; $info.Waiting = $false }
            'task_complete'     { $info.Waiting = $true }
        }
    }
    $info
}

$script:CodexHookCache = $null
$script:ClaudeHookCache = $null
function Get-ClaudeHookState {
    # Written by hooks/fleet-hook.js, wired from ~/.claude/settings.json. Keyed by session id,
    # which is what `claude agents --json` already reports, so no matching heuristic.
    # Replaces two transcript scans: the first ask (read from the file head) and the last
    # assistant text (read from the tail). Both are now recorded when they happen.
    if ($null -ne $script:ClaudeHookCache) { return $script:ClaudeHookCache }
    $map = @{}
    $dir = Join-Path $FleetCfg.StateDir 'claude'
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($j.sessionId) { $map[$j.sessionId] = $j }
        }
    }
    $script:ClaudeHookCache = $map
    return $map
}

function Get-CodexHookState {
    # Written by hooks/fleet-hook.js, wired from ~/.codex/hooks.json. This is
    # the only place Codex liveness comes from a fact rather than a guess: the old path
    # decided "is it mid-turn" by looking for a task_complete event in the rollout tail.
    # Covers every profile and every `codex exec` lane, unlike the app-server thread list.
    if ($null -ne $script:CodexHookCache) { return $script:CodexHookCache }
    $map = @{}
    $dir = Join-Path $FleetCfg.StateDir 'codex'
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($j.transcriptPath) { $map[$j.transcriptPath.ToLower()] = $j }
        }
    }
    $script:CodexHookCache = $map
    return $map
}

$script:CodexThreadCache = $null
function Get-CodexThreads {
    # Ask the Codex app-server what its threads actually are, instead of regexing the
    # rollout for the same facts. It answers with name, cwd, git branch, model, source and
    # a real thread id - see lib/codex-threads.js.
    # Covers the DEFAULT codex home only (~/.codex); the app-server returns nothing when
    # CODEX_HOME is set. Other profiles simply get no enrichment.
    if ($null -ne $script:CodexThreadCache) { return $script:CodexThreadCache }
    $cache = Join-Path $FleetCfg.StateDir 'codex-threads.json'
    # thread/list takes seconds to a minute, so never block the dashboard on it. Read the
    # cache, and kick off a background refresh when it is stale. Thread metadata (name,
    # branch, cwd, model) barely changes, so a few minutes old is fine.
    $stale = -not (Test-Path $cache) -or ((Get-Date) - (Get-Item $cache).LastWriteTime).TotalMinutes -gt 10
    if ($stale) {
        try {
            Start-Process -FilePath 'node' -WindowStyle Hidden -ArgumentList @(
                "$PSScriptRoot\lib\codex-threads.js", '--limit', '40', '--out', $cache
            ) | Out-Null
        } catch { }
    }
    $map = @{}
    if (Test-Path $cache) {
        try {
            foreach ($t in (Get-Content $cache -Raw | ConvertFrom-Json)) {
                if ($t.path) { $map[$t.path.ToLower()] = $t }
            }
        } catch { }
    }
    $script:CodexThreadCache = $map
    return $map
}

function Get-StatusFile($sessionId) {
    # Authoritative: the session itself writes this, when you ask your agents to keep one.
    # <stateDir>\<session-id>.json holding {"plan":"<slug>","done":3,"total":8,"current":4}.
    # No guessing.
    $f = Join-Path $FleetCfg.StateDir "$sessionId.json"
    if (-not (Test-Path $f)) { return $null }
    try { $j = Get-Content $f -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $j.done -or -not $j.total) { return $null }
    [pscustomobject]@{ Done = [int]$j.done; Total = [int]$j.total; Current = $j.current; Plan = $j.plan; Exact = $true }
}

function Get-PlanProgress($logPath) {
    $tail = Get-TailLines $logPath
    # Ledgers are referenced by slug, sometimes as a relative path, so match the slug and
    # resolve it on disk rather than trusting the text to carry a full path.
    $slugs = $tail | Select-String -Pattern '\.superpowers[\/]{1,2}sdd[\/]{1,2}([A-Za-z0-9][A-Za-z0-9._-]{6,})' -AllMatches |
             ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } |
             Where-Object { $_ -notmatch '\.md$' } |
             Group-Object | Sort-Object Count -Descending
    $roots = @($tail | Select-String -Pattern '"cwd":"([^"]+)"' -AllMatches | ForEach-Object { $_.Matches } |
               ForEach-Object { ($_.Groups[1].Value -replace '\\', '\') } |
               Where-Object { $_ -match '^[A-Za-z]:' } | Select-Object -Unique)
    $cands = @()
    foreach ($slug in ($slugs | ForEach-Object { $_.Name })) {
        foreach ($r in $roots) {
            $cand = Join-Path $r ".superpowers\sdd\$slug"
            if (Test-Path (Join-Path $cand 'progress.md')) { $cands += $cand }
        }
    }
    if (-not $cands) {
        # slug never appeared in the window: only trust a ledger sitting in this session's own cwd
        foreach ($r in $roots) {
            $sdd = Join-Path $r '.superpowers\sdd'
            if (Test-Path $sdd) {
                $cands += @(Get-ChildItem $sdd -Directory -ErrorAction SilentlyContinue |
                            Where-Object { Test-Path (Join-Path $_.FullName 'progress.md') } | ForEach-Object { $_.FullName })
            }
        }
    }
    # Ambiguous is worse than absent: a repo full of ledgers gives no way to know which one
    # this session is on, so report nothing unless there is exactly one candidate.
    $cands = @($cands | Select-Object -Unique)
    if ($cands.Count -ne 1) { return $null }
    $dir = $cands[0]

    if (-not $dir) { return $null }

    $prog = Join-Path $dir 'progress.md'
    if (-not (Test-Path $prog)) { return $null }
    $lines = Get-Content $prog

    # Ledger dialects differ ("Task 3: complete", "Wave 2: Task 1 complete") - match the
    # claim anywhere on the line, and never count a negated one.
    $done = @($lines | Where-Object { $_ -notmatch '(?i)not complete|incomplete|to complete|before complete' } |
              Select-String -Pattern '(?i)Task\s+(\d+)\b[^\r\n]{0,60}?\bcomplete' |
              ForEach-Object { [int]$_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
    # "## Phase 1 complete" + "Phase 1 = Tasks 0-9, 11-14, 16" means every listed task is done,
    # even when only the first few have their own per-task lines.
    $phaseDone = @()
    foreach ($ph in ($lines | Select-String -Pattern '(?i)Phase\s+(\d+)[^
]{0,30}?complete' | ForEach-Object { $_.Matches[0].Groups[1].Value })) {
        $map = $lines | Select-String -Pattern "(?i)Phase\s+$ph\s*=\s*Tasks?\s+([0-9,\s-]+)" | Select-Object -First 1
        if (-not $map) { continue }
        foreach ($part in ($map.Matches[0].Groups[1].Value -split ',')) {
            $part = $part.Trim()
            if ($part -match '^(\d+)\s*-\s*(\d+)$') { $phaseDone += [int]$Matches[1]..[int]$Matches[2] }
            elseif ($part -match '^(\d+)$')            { $phaseDone += [int]$Matches[1] }
        }
    }
    $done = @($done + $phaseDone | Sort-Object -Unique)
    $seen = @($lines | Select-String -Pattern '(?i)\bTask\s+(\d+)\b' -AllMatches |
              ForEach-Object { $_.Matches } | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    $briefs = @(Get-ChildItem $dir -Filter 'task-*-brief.md' -ErrorAction SilentlyContinue |
                ForEach-Object { if ($_.Name -match 'task-(\d+)-brief') { [int]$Matches[1] } })

    $planTasks = 0
    if ($lines[0] -match 'plan:\s*(\S+\.md)') {
        $root = $dir -replace '\\.superpowers\sdd\.*$', ''
        $planPath = Join-Path $root ($Matches[1] -replace '/', '\')
        if (Test-Path $planPath) {
            $nums = @(Select-String -Path $planPath -Pattern '^#+\s*Task\s+(\d+)' |
                      ForEach-Object { [int]$_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
            if ($nums) { $planTasks = ($nums | Measure-Object -Maximum).Maximum + $(if (($nums | Measure-Object -Minimum).Minimum -eq 0) { 1 } else { 0 }) }
        }
    }
    $maxId = (@(0) + $seen + $briefs | Measure-Object -Maximum).Maximum
    $total = (@($planTasks, ($maxId + $(if (($seen + $briefs | Measure-Object -Minimum).Minimum -eq 0) { 1 } else { 0 }))) | Measure-Object -Maximum).Maximum
    if (-not $total) { return $null }
    [pscustomobject]@{ Done = $done.Count; Total = $total; Current = ($seen | Measure-Object -Maximum).Maximum; Plan = Split-Path $dir -Leaf }
}

function Get-Progress($cfgDir, $sessionId) {
    $dir = "$cfgDir\tasks\session-$($sessionId.Substring(0,8))"
    if (-not (Test-Path $dir)) { return $null }
    $tasks = Get-ChildItem $dir -Filter *.json -ErrorAction SilentlyContinue |
             ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch {} }
    if (-not $tasks) { return $null }
    [pscustomobject]@{
        Done  = @($tasks | Where-Object status -eq 'completed').Count
        Total = @($tasks).Count
    }
}

# One coloured line per session. A card is five lines tall, so eight sessions fill a pane
# and you scroll to see the fleet you opened the pane to watch. This keeps the colour, the
# progress bar and the state dot, and drops the borders.
function Show-CompactRows($rows) {
    $C = Get-TuiColors; $G = Get-TuiGlyphs
    $lay = Get-Layout -Width $Width
    $w = $lay.Width

    $hidden = 0
    foreach ($r in $rows) {
        if (-not $All -and $r.State -eq 'done' -and $r.IdleMin -gt 60) { $hidden++; continue }

        $dot = switch ($r.State) { 'WAITING' { $C.red } 'working' { $C.blue } default { $C.grey } }
        $state = switch ($r.State) {
            'WAITING' { "$($C.red)needs you$($C.reset)" }
            'working' { "$($C.blue)working  $($C.reset)" }
            'done'    { "$($C.grey)done     $($C.reset)" }
            default   { "$($C.grey)idle     $($C.reset)" }
        }

        # Fixed columns first, then give whatever is left to the label - that is the part
        # worth reading, and it is the only column that should absorb a narrow pane.
        $acct  = '{0,-8}' -f (Fit $r.Acct 8)
        $where = '{0,-16}' -f (Fit $r.Where 16)
        $idle  = '{0,4}' -f $r.Idle

        # Session name, right of the folder. Claude Code auto-names a session after its
        # folder plus a random suffix (api-server-a9), which is noise; a name you typed with
        # /rename is signal. Show both, but dim the generated ones so the deliberate ones
        # stand out. Dropped entirely on a narrow pane, where the label matters more.
        # What is this session, beyond its folder? Best answer first:
        #   1. a name you typed with /rename - the only one that states intent
        #   2. the git branch, when it is not the default - distinguishes worktrees
        #   3. nothing, which is honest: two sessions in the same folder on main are
        #      genuinely not distinguishable from the outside
        # Generated names end in a short random suffix (api-server-a9, docs-a5, github-64),
        # and carry no information at all, so they never win.
        $nameCol = ''
        if ($w -ge 100) {
            $auto = (-not $r.Name) -or ($r.Name -match '-[0-9a-z]{2,3}$')
            if (-not $auto) {
                $nameCol = "$($C.white)$('{0,-14}' -f (Fit $r.Name 14))$($C.reset) "
            } elseif ($r.Branch) {
                $nameCol = "$($C.grey)$('{0,-14}' -f (Fit $r.Branch 14))$($C.reset) "
            } else {
                $nameCol = ' ' * 15
            }
        }
        if ($null -ne $r.Pct) {
            $bar  = Render-Bar $r.Pct $null 10 (Pct-Color $r.Pct)
            $prog = "$($C.grey)$('{0,5}' -f $r.Prog)$($C.reset) $(Pct-Color $r.Pct)$('{0,3}' -f $r.Pct)%$($C.reset)"
        } else {
            $bar  = ' ' * 10
            $prog = ' ' * 10
        }

        $fixed = "$dot$($G.dot)$($C.reset) $($C.bold)$acct$($C.reset) $($C.grey)$where$($C.reset) $nameCol$state $($C.grey)$idle$($C.reset) $bar $prog "
        $room = [Math]::Max(12, $w - (Vis-Len $fixed) - 1)
        "$fixed$(Fit $r.Label $room)"
    }
    if ($hidden) { "  $($C.grey)($hidden finished, idle >1h - see -All)$($C.reset)" }
}

function Show-Cards($rows) {
    $C = Get-TuiColors; $G = Get-TuiGlyphs
    $lay = Get-Layout -MaxInner 52 -Width $Width
    $inner = $lay.Inner

    $hidden = 0
    # An ArrayList, not += on an array: += unrolls each card's line array into loose
    # strings, which silently turns 2 cards into 10 broken rows.
    $cards = [System.Collections.ArrayList]@()
    foreach ($r in $rows) {
        if (-not $All -and $r.State -eq 'done' -and $r.IdleMin -gt 60) { $hidden++; continue }

        # The dot carries state at a glance: red wants you, blue is mid-flight, grey is done.
        $dot = switch ($r.State) {
            'WAITING' { $C.red }
            'working' { $C.blue }
            default   { $C.grey }
        }
        $stateTxt = switch ($r.State) {
            'WAITING' { "$($C.red)needs you$($C.reset)" }
            'working' { "$($C.blue)working$($C.reset)" }
            'done'    { "$($C.grey)done$($C.reset)" }
            default   { "$($C.grey)idle$($C.reset)" }
        }

        $lines = @()
        $left = "$dot$($G.dot)$($C.reset) $($C.bold)$(Fit $r.Acct 12)$($C.reset) $($C.grey)$($G.middot)$($C.reset) $(Fit $r.Where 20)"
        $lines += Split-Line $left "$stateTxt $($C.grey)$($r.Idle)$($C.reset)" $inner
        $lines += ''
        $lines += "$($C.white)$(Fit $r.Label $inner)$($C.reset)"

        if ($null -ne $r.Pct) {
            $barW = $inner - 14
            $bar = Render-Bar $r.Pct $null $barW (Pct-Color $r.Pct)
            $lines += "$bar $($C.grey)$('{0,5}' -f $r.Prog)$($C.reset) $(Pct-Color $r.Pct)$('{0,3}' -f $r.Pct)%$($C.reset)"
        }

        # Not $detail: PowerShell names are case-insensitive, so it would clobber the
        # -Detail switch and force the extra rows on for everyone.
        $fields = @()
        if ($r.Doing)  { $fields += @{ k = 'doing'; v = $r.Doing } }
        if ($Detail -and $r.Chat) { $fields += @{ k = 'chat'; v = $r.Chat } }
        if ($Detail -and $r.Ask)  { $fields += @{ k = 'ask'; v = $r.Ask } }
        if ($r.Model -or $r.Source) {
            $fields += @{ k = 'via'; v = (@($r.Model, $r.Source) | Where-Object { $_ }) -join " $($G.middot) " }
        }
        if ($fields) { $lines += '' }
        foreach ($d in $fields) {
            $lines += "$($C.grey)$('{0,-6}' -f $d.k)$($C.reset) $(Fit $d.v ($inner - 7))"
        }

        [void]$cards.Add((Build-Card $lines $inner))
    }

    if ($cards.Count -eq 0) { "  $($C.grey)(none)$($C.reset)"; return }
    Write-Grid $cards $inner $lay.TwoUp
    if ($hidden) { "  $($C.grey)($hidden finished, idle >1h - see -All)$($C.reset)" }
}

function Show-Rows($rows, [switch]$Group) {
    if (-not $rows) { return }
    # Collapse fan-out lanes: N workers on the same task read as one line, not N.
    # Group on a real id when the app-server gave us one - children of the same parent
    # thread ARE one lane. Only fall back to the text key when there is no id, because
    # two unrelated sessions can share the first 30 characters of a prompt (every
    # `/investigate ...` run does) and would otherwise be merged into a single wrong row.
    if ($Group) {
        $rows = $rows | Group-Object {
            if ($_.ParentId) { "parent:{0}" -f $_.ParentId }
            elseif ($_.ThreadId) { "thread:{0}" -f $_.ThreadId }
            else { "{0}|{1}|{2}" -f $_.Acct, $_.Where, (Trunc $_.Chat 30) }
        } | ForEach-Object {
            $r = $_.Group | Sort-Object IdleMin | Select-Object -First 1
            if ($_.Count -gt 1) { $r.Label = "{0}  x{1}" -f $r.Label, $_.Count }
            $r
        }
    }
    # Anything waiting on you first; then the busiest; stale finished lanes last.
    $order = @{ 'WAITING' = 0; 'working' = 1; 'done' = 2; 'idle' = 2 }
    $rows = $rows | Sort-Object @{e={ $order[$_.State] }}, IdleMin
    # $Compact, not $Rows: inside Show-Rows($rows,...) a switch named $Rows collides with
    # the local $rows array - PowerShell names are case-insensitive - and a non-empty
    # array is truthy, so every mode silently rendered compact.
    if ($Compact) { Show-CompactRows $rows; return }
    if ($UseCards) { Show-Cards $rows; return }
    $hidden = 0
    foreach ($r in $rows) {
        if (-not $All -and $r.State -eq 'done' -and $r.IdleMin -gt 60) { $hidden++; continue }
        $flag = switch ($r.State) { 'WAITING' { '>>' } 'working' { '..' } default { 'ok' } }
        $pct  = if ($null -ne $r.Pct) { "{0,3}%" -f $r.Pct } else { '    ' }
        "  {0} {1,-7} {2,-17} {3,-7} {4} {5,4}  {6}" -f $flag, (Trunc $r.Acct 12), (Trunc $r.Where 17), $r.Prog, $pct, $r.Idle, (Trunc $r.Label 46)
        if ($Detail) {
            if ($r.Plan)  { "       plan:  " + (Trunc $r.Plan 74) }
            if ($r.Chat)  { "       chat:  " + (Trunc $r.Chat 74) }
            if ($r.Ask)   { "       ask:   " + (Trunc $r.Ask 74) }
            if ($r.Doing) { "       doing: " + (Trunc $r.Doing 74) }
        }
    }
    if ($hidden) { "  ({0} finished, idle >1h - see -All)" -f $hidden }
}

# Demo rows have the same shape the live readers build, so every renderer runs unchanged.
# Times are stored as minutes ago, so the demo never looks stale.
function Get-DemoRows($list, $now) {
    foreach ($raw in @($list)) {
        $d = Resolve-DemoEntry $raw $DemoTick
        # One tick is one minute of story. A working session is active, so its idle time
        # stays put; anything else has been idle since its state began.
        if ($d.state -ne 'working') { $d.idleMin = [int]$d.idleMin + ($d.tick - $d.stateSince) }
        [pscustomobject]@{
            Acct = $d.account; Where = $d.where; State = $d.state
            Age = (Span $now.AddMinutes(-$d.ageMin)); Idle = (Span $now.AddMinutes(-$d.idleMin)); IdleMin = [int]$d.idleMin
            Pct = $(if ($d.total) { [int](100 * $d.done / $d.total) } else { $null })
            Prog = $(if ($d.total) { "{0}/{1}" -f $d.done, $d.total } else { '' })
            Label = $(if ($d.plan) { $d.plan } elseif ($d.title) { $d.title } elseif ($d.chat) { $d.chat } else { $d.name })
            Name = $d.name; Chat = $d.chat; Ask = $d.ask; Doing = $d.doing; Plan = $d.plan; Branch = $d.branch
            ThreadId = $d.threadId; ParentId = $d.parentId; Model = $d.model; Source = $d.source
        }
    }
}

# Every account's transcripts. Profile dirs often link their projects folder back to the
# main one, so resolve links first or the same transcript would be listed once per account.
function Get-ClaudeLogs {
    $dirs = foreach ($a in $accounts) {
        $p = Join-Path $a.ClaudeDir 'projects'
        if (-not (Test-Path $p)) { continue }
        $item = Get-Item $p -Force
        if ($item.LinkTarget) { try { $item.ResolveLinkTarget($true).FullName } catch { $item.FullName } } else { $item.FullName }
    }
    foreach ($d in @($dirs | Select-Object -Unique)) {
        Get-ChildItem $d -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue
    }
}

function Show-Fleet {
    $now = Get-Date
    $hdr = "CLAUDE"
    $fixture = if ($Demo) { Get-Content (Join-Path $PSScriptRoot 'demo\fixture.json') -Raw | ConvertFrom-Json } else { $null }
    $logs = if ($Demo) { @() } else { @(Get-ClaudeLogs) }
    $claudeHooks = if ($Demo) { @{} } else { Get-ClaudeHookState }
    $found = $false
    $rows = @()
    if ($Demo) { $rows = @(Get-DemoRows $fixture.claude $now) }
    foreach ($account in $(if ($Demo) { @() } else { $accounts })) {
        $acct = $account.Name
        $cfg = $account.ClaudeDir
        $old = (Get-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue).Value
        if (-not $account.ClaudeEnv) { Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue } else { Set-Item env:CLAUDE_CONFIG_DIR $account.ClaudeEnv }
        $agents = @()
        try { $agents = @((claude agents --json 2>&1) -join "`n" | ConvertFrom-Json) } catch {}
        if ($old) { Set-Item env:CLAUDE_CONFIG_DIR $old } else { Remove-Item env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }

        foreach ($a in $agents) {
            $found = $true
            $log = $logs | Where-Object BaseName -eq $a.sessionId | Select-Object -First 1
            $act = if ($log) { Get-Activity $log.FullName } else { $null }
            $idle = if ($log) { Span $log.LastWriteTime } else { '?' }
            $age  = if ($a.startedAt) { Span ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$a.startedAt).LocalDateTime) } else { '?' }
            $state = if ($a.status -eq 'busy') { 'working' }
                     elseif ($act -and $act.Waiting) { 'WAITING' }
                     else { 'idle' }
            $pp = Get-StatusFile $a.sessionId
            # Ledger-derived numbers are guesses (which of a repo's many ledgers is this
            # session on?). Off by default - a wrong percentage is worse than none.
            if (-not $pp -and $log -and $Approx) { $pp = Get-PlanProgress $log.FullName }
            $pr = Get-Progress $cfg $a.sessionId
            $tasks = if ($pp)      { "  {0}{1}/{2} {3,3:N0}% (on task {4})" -f $(if ($pp.Exact) { '' } else { '~' }), $pp.Done, $pp.Total, (100 * $pp.Done / $pp.Total), $pp.Current }
                     elseif ($pr)  { "  {0}/{1} tasks" -f $pr.Done, $pr.Total } else { '' }
            $where = if ($act -and $act.Worktree) { $act.Worktree } else { Split-Path $a.cwd -Leaf }
            # Prefer what the hook recorded over what the transcript scan guessed. The
            # fallbacks stay for sessions that started before the hooks were installed.
            $hk = $claudeHooks[$a.sessionId]
            $chat = if ($hk -and $hk.firstAsk) { $hk.firstAsk }
                    elseif ($log) { Get-FirstAsk $log.FullName } else { $null }
            if ($hk -and $hk.lastSaid -and $act -and $act.Waiting) { $act.Doing = $hk.lastSaid }
            $rows += [pscustomobject]@{
                Acct = $acct; Where = $where; State = $state; Age = $age; Idle = $idle
                IdleMin = $(if ($log) { [int]($now - $log.LastWriteTime).TotalMinutes } else { 9999 })
                Pct = $(if ($pp) { [int](100 * $pp.Done / $pp.Total) } else { $null })
                Prog = $(if ($pp) { "{0}{1}/{2}" -f $(if ($pp.Exact) { '' } else { '~' }), $pp.Done, $pp.Total } else { '' })
                Label = $(if ($pp -and $pp.Plan) { $pp.Plan } elseif ($chat) { $chat } else { $a.name })
                Name = $a.name; Chat = $chat; Ask = $act.Ask; Doing = $act.Doing; Plan = $(if ($pp) { $pp.Plan } else { $null })
                Branch = (Get-Branch $a.cwd)
            }
        }
    }
    $need = @($rows | Where-Object State -eq 'WAITING').Count
    "{0,-46}{1}{2:HH:mm:ss}" -f "CLAUDE   >> needs you  .. working  ok done", $(if ($need) { "$need NEED YOU   " } else { '' }), $now
    if (-not $rows) { "  (none running)" }
    Show-Rows $rows


    "`nCODEX  (sessions touched in the last $Hours h)"
    $any = $false
    $crows = @()
    if ($Demo) { $crows = @(Get-DemoRows $fixture.codex $now) }
    foreach ($account in $(if ($Demo) { @() } else { $accounts })) {
        $acct = $account.Name
        $dir = $account.CodexDir
        $recent = Get-ChildItem "$dir\sessions" -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt $now.AddHours(-$Hours) } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 6
        $threads = Get-CodexThreads
        $hookState = Get-CodexHookState
        foreach ($f in $recent) {
            $any = $true
            $ci = Get-CodexInfo $f.FullName
            $th = $threads[$f.FullName.ToLower()]
            $hs = $hookState[$f.FullName.ToLower()]
            # Looked up, not guessed: the branch comes from the thread's own gitInfo rather
            # than a regex over the cwd string, and the label from its recorded name.
            $where = if ($th -and $th.branch) { $th.branch }
                     elseif ($th -and $th.cwd) { Split-Path $th.cwd -Leaf }
                     elseif ($ci.Cwd) { Split-Path $ci.Cwd -Leaf } else { '?' }
            # The hook wrote what the session actually did; fall back to the rollout guess
            # only for sessions that started before the hooks were installed.
            $state = if ($hs) {
                switch ($hs.state) {
                    'waiting' { 'WAITING' }
                    'ended'   { 'done' }
                    default   { 'working' }
                }
            } elseif ($ci.Waiting) { 'done' } else { 'working' }
            $cp = if ($ci.SessionId) { Get-StatusFile $ci.SessionId } else { $null }
            if (-not $cp -and $Approx) { $cp = Get-PlanProgress $f.FullName }
            $cpTxt = if ($cp) { "  {0}{1}/{2} {3,3:N0}% (on task {4})" -f $(if ($cp.Exact) { '' } else { '~' }), $cp.Done, $cp.Total, (100 * $cp.Done / $cp.Total), $cp.Current } else { '' }
            $crows += [pscustomobject]@{
                Acct = $acct; Where = $where; State = $state; Age = (Span $f.CreationTime); Idle = (Span $f.LastWriteTime)
                IdleMin = [int]($now - $f.LastWriteTime).TotalMinutes
                Pct = $(if ($cp) { [int](100 * $cp.Done / $cp.Total) } else { $null })
                Prog = $(if ($cp) { "{0}{1}/{2}" -f $(if ($cp.Exact) { '' } else { '~' }), $cp.Done, $cp.Total } else { '' })
                # The thread's own name beats the first user message: Codex writes a real
                # title, and the first message is often a pasted blob of context.
                Label = $(if ($cp -and $cp.Plan) { $cp.Plan } elseif ($th -and $th.name) { $th.name } elseif ($ci.Chat) { $ci.Chat } else { '?' })
                Name = ''; Chat = $(if ($th -and $th.preview) { $th.preview } else { $ci.Chat })
                Ask = $ci.Ask; Doing = $ci.Doing; Plan = $(if ($cp) { $cp.Plan } else { $null })
                # Real ids, so fan-out lanes can be collapsed by identity instead of by
                # matching the first 30 characters of a prompt.
                Branch = $(if ($th -and $th.branch -and $th.branch -notin @('main','master')) { $th.branch } else { $null })
                ThreadId = $(if ($th) { $th.id } else { $null })
                ParentId = $(if ($th) { $th.parentThreadId } else { $null })
                Model = $(if ($th) { $th.model } else { $null })
                Source = $(if ($th) { $th.source } else { $null })
            }
        }
    }
    if (-not $crows) { "  (none in window)" }
    Show-Rows $crows -Group


    if ($Usage) { ""; & "$PSScriptRoot\ai-usage.ps1" -Plain -Demo:$Demo -DemoTick $DemoTick }
}

if ($Watch -and $Demo) {
    Clear-Host
    # The demo is a story, so it moves at one step a second unless -Every says otherwise.
    if (-not $PSBoundParameters.ContainsKey('Every')) { $Every = 1 }
    while ($true) {
        # Build the whole frame, then overwrite the screen in place with one write. Clearing
        # first would show a blank frame between refreshes, which reads as flicker.
        $frame = @(Show-Fleet) + @('', "(demo refreshing every $Every s - Ctrl+C to stop)")
        Write-Host -NoNewline ("$ESC[H" + ($frame -join "$ESC[K`n") + "$ESC[K$ESC[J")
        $DemoTick++
        Start-Sleep -Seconds $Every
    }
} elseif ($Watch) {
    while ($true) { Clear-Host; Show-Fleet; "`n(refreshing every $Every s - Ctrl+C to stop)"; Start-Sleep -Seconds $Every }
} else { Show-Fleet }
