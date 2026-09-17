# vitals - one pane for machine health: memory, commit, CPU, disks, processes, crashes.
#
# Windows only: it reads CIM performance classes and the Windows event log.
#
# Built for chasing crashes, so it leads with the two numbers that actually predict one
# on Windows and that Task Manager buries: commit charge (allocations start failing when
# the commit limit is hit, which is what kills Node with "heap out of memory" long before
# RAM is full) and the real crash record from the event log.
#
# A snapshot cannot tell you what ate the RAM at 3am, so a run can append one line to a
# small log. Point Task Scheduler at `vitals -Log` every few minutes and the history is
# already there the next time the machine dies.
#
#   vitals              one snapshot
#   vitals -Watch       refreshes every -Every (default 60s), logs each frame
#   vitals -Days 30     widen the crash lookback (default 14)
#   vitals -Top 12      show more process groups (default 8)
#   vitals -History     hourly peaks from the log instead of a snapshot
#   vitals -Hours 48    how far back -History reads (default 24)
#   vitals -Log         append one sample to the log and exit (for Task Scheduler)
#   vitals -Json        machine-readable snapshot
#   vitals -Ascii       no colour/unicode - screenshots, non-UTF8 consoles
#   vitals -Once        force a single frame even if -Watch is also passed

param(
    [switch]$Watch,
    [switch]$Once,
    # 60s, not 10s: one frame costs ~1.0s of CPU because two of its queries walk all
    # ~650 processes. At 10s that is 0.5% of a 20-core box burned on numbers that barely
    # move in ten seconds; at 60s it is 0.09%. Measured, not guessed.
    [string]$Every = '60s',
    [switch]$Ascii,
    [int]$Days = 14,
    [int]$Hours = 24,
    [int]$Top = 8,
    [switch]$Json,
    [switch]$Log,
    [switch]$History,
    # Override the console width. Only for testing that the layout holds at 80 or 160
    # columns, which cannot be done otherwise since WindowWidth is not settable.
    [int]$Width = 0
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\tui.ps1"
. "$PSScriptRoot\lib\config.ps1"
Init-Tui -Ascii:$Ascii
$C = Get-TuiColors
$G = Get-TuiGlyphs
$ESC = [char]27

$script:Cores = [Environment]::ProcessorCount
$script:LogPath = (Get-FleetConfig).VitalsLog

# Same contract as dash's -Every. The 5s floor stays available for watching something
# change in real time, but it is not the default: a frame costs ~1.0s of CPU, so a tight
# interval is a real cost. The upper bound is still there because a dashboard that never
# refreshes is a bug, not a feature.
function Parse-Every($s) {
    if ($s -notmatch '^\s*(\d+)\s*([smh])\s*$') { throw "-Every wants something like 30s, 2m, or 1h (got '$s')" }
    $n = [int]$Matches[1]
    $secs = switch ($Matches[2]) { 's' { $n } 'm' { $n * 60 } 'h' { $n * 3600 } }
    if ($secs -lt 5) { throw '-Every must be at least 5s' }
    if ($secs -gt 86400) { throw '-Every must be 24h or less' }
    return $secs
}

# --- collection -----------------------------------------------------------------

function Fmt-GB($gb) {
    if ($null -eq $gb) { return '?' }
    if ($gb -ge 100) { return '{0:N0}G' -f $gb }
    if ($gb -ge 10)  { return '{0:N1}G' -f $gb }
    return '{0:N2}G' -f $gb
}

# Big counts in as few columns as possible: 1.24M rather than 1,239,259.
function Fmt-Count($n) {
    if ($null -eq $n) { return '?' }
    if ($n -ge 1000000) { return '{0:N2}M' -f ($n / 1000000) }
    if ($n -ge 1000) { return '{0:N0}k' -f ($n / 1000) }
    return '{0:N0}' -f $n
}

function Get-MemStats {
    $os = Get-CimInstance Win32_OperatingSystem
    $m = @{}
    $m.RamTotalGB = [double]$os.TotalVisibleMemorySize / 1MB   # the counter is in KB
    $m.RamFreeGB  = [double]$os.FreePhysicalMemory / 1MB
    $m.RamUsedGB  = $m.RamTotalGB - $m.RamFreeGB
    $m.RamPct     = if ($m.RamTotalGB -gt 0) { 100 * $m.RamUsedGB / $m.RamTotalGB } else { $null }

    # Commit is the number that answers "why did Node die". The perf class is the direct
    # read; the virtual-memory fields on Win32_OperatingSystem are the same idea measured
    # more loosely, and are here so this still works when the counters are broken.
    try {
        $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $m.CommitUsedGB   = [double]$pm.CommittedBytes / 1GB
        $m.CommitTotalGB  = [double]$pm.CommitLimit / 1GB
        $m.PagesPerSec    = [double]$pm.PagesPerSec
        $m.PoolNonpagedGB = [double]$pm.PoolNonpagedBytes / 1GB
    } catch {
        $tv = [double]$os.TotalVirtualMemorySize / 1MB
        $fv = [double]$os.FreeVirtualMemory / 1MB
        $m.CommitTotalGB  = $tv
        $m.CommitUsedGB   = $tv - $fv
        $m.PagesPerSec    = $null
        $m.PoolNonpagedGB = $null
    }
    $m.CommitPct = if ($m.CommitTotalGB -gt 0) { 100 * $m.CommitUsedGB / $m.CommitTotalGB } else { $null }
    $m.UptimeSince = $os.LastBootUpTime
    return $m
}

function Get-CpuStats {
    $c = @{ Pct = $null; Queue = $null }
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $c.Pct = [double]$p.PercentProcessorTime
    } catch {}
    try {
        $s = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop
        $c.Queue = [int]$s.ProcessorQueueLength
    } catch {}
    return $c
}

function Get-DiskStats {
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $total = [double]$_.Size / 1GB
        $free  = [double]$_.FreeSpace / 1GB
        [pscustomobject]@{
            Drive   = $_.DeviceID
            TotalGB = $total
            FreeGB  = $free
            UsedPct = if ($total -gt 0) { 100 * ($total - $free) / $total } else { $null }
        }
    }
}

# A bucket for a node process, read off its command line. There is no id to look up here
# - the command line is the only thing that says what a node process is - so these are
# labels for a human to read, never a fact anything else decides on.
function Classify-Node($cmd) {
    if (-not $cmd) { return 'node: unknown' }
    $c = $cmd.ToLower()
    # Order matters: the first match wins, so the narrow owners come before the broad
    # tool names. An MCP server started by npx would otherwise land in "package manager".
    if ($c -match 'claude|@anthropic-ai') { return 'node: claude' }
    if ($c -match 'openai\\codex|[\\/ ]codex') { return 'node: codex' }
    if ($c -match 'mcp|modelcontextprotocol') { return 'node: mcp servers' }
    if ($c -match 'tsc |typescript|typecheck|jest|vitest|mocha|eslint|guardrail|gate:|lint') { return 'node: builds + tests' }
    if ($c -match 'vite|next|webpack|nodemon|esbuild|turbopack|tsx |ts-node') { return 'node: dev servers' }
    if ($c -match 'tsserver|language.?server') { return 'node: language servers' }
    if ($c -match 'pnpm|npx|npm-cli|yarn') { return 'node: package manager' }
    return 'node: other'
}

# A one-line hint of what a process is, for the few biggest ones. A bare "node" tells you
# nothing when one of thirty is the one eating the machine.
function Describe-Proc($name, $cmd) {
    if ($name -ne 'node' -or -not $cmd) { return $name }
    $c = ($cmd -replace '\s+', ' ').Trim()
    # Drop the interpreter path and any --flags so what is left is the script being run.
    $c = $c -replace '^"[^"]*"\s*', '' -replace '^\S*node(\.exe)?"?\s*', ''
    $parts = @($c -split ' ' | Where-Object { $_ -and $_ -notmatch '^-' })
    if (-not $parts.Count) { return 'node' }
    $leaf = ($parts[0] -replace '"', '') -replace '^.*[\\/]', ''
    $rest = if ($parts.Count -gt 1) { ' ' + (($parts[1..($parts.Count - 1)] | Select-Object -First 2) -join ' ') } else { '' }
    return "node $leaf$rest"
}

function Get-ProcStats {
    $procs = Get-CimInstance Win32_Process
    # Per-process CPU has to come from the perf class. Get-Process gives cumulative CPU
    # seconds since the process started, which says nothing about what is busy right now.
    $cpuByPid = @{}
    try {
        foreach ($p in Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop) {
            if ($p.IDProcess) { $cpuByPid[[int]$p.IDProcess] = [double]$p.PercentProcessorTime }
        }
    } catch {}

    $rows = foreach ($p in $procs) {
        $name = $p.Name -replace '\.exe$', ''
        $label = if ($name -eq 'node') { Classify-Node $p.CommandLine } else { $name }
        # The counter reads 100 per busy core, so a 16-core box tops out at 1600. Divide
        # by the core count to get a share of the whole machine, like Task Manager shows.
        $cpu = if ($cpuByPid.ContainsKey([int]$p.ProcessId)) { $cpuByPid[[int]$p.ProcessId] / $script:Cores } else { 0 }
        [pscustomobject]@{
            Label   = $label
            Name    = $name
            Desc    = $null
            Pid     = [int]$p.ProcessId
            Cmd     = $p.CommandLine
            WsGB    = [double]$p.WorkingSetSize / 1GB
            Cpu     = $cpu
            Handles = [int]$p.HandleCount
            Threads = [int]$p.ThreadCount
        }
    }

    $groups = $rows | Group-Object Label | ForEach-Object {
        [pscustomobject]@{
            Label   = $_.Name
            Count   = $_.Count
            WsGB    = ($_.Group | Measure-Object WsGB -Sum).Sum
            Cpu     = ($_.Group | Measure-Object Cpu -Sum).Sum
            Handles = ($_.Group | Measure-Object Handles -Sum).Sum
            Threads = ($_.Group | Measure-Object Threads -Sum).Sum
        }
    }

    # The biggest single process, not the biggest group. A 6.7GB tsc hides inside a
    # "node" group of thirty, and the single process is the one you go and kill.
    $singles = @($rows | Sort-Object WsGB -Descending | Select-Object -First 5 | ForEach-Object {
        [pscustomobject]@{
            Desc = Describe-Proc $_.Name $_.Cmd
            Pid  = $_.Pid
            WsGB = $_.WsGB
            Cpu  = $_.Cpu
        }
    })

    $node = @($rows | Where-Object { $_.Name -eq 'node' })
    return @{
        Singles    = $singles
        Groups     = @($groups | Sort-Object WsGB -Descending)
        Total      = @($rows).Count
        NodeCount  = $node.Count
        NodeWsGB   = if ($node.Count) { ($node | Measure-Object WsGB -Sum).Sum } else { 0 }
        NodeGroups = @($groups | Where-Object { $_.Label -like 'node:*' } | Sort-Object WsGB -Descending)
        Handles    = ($rows | Measure-Object Handles -Sum).Sum
        Threads    = ($rows | Measure-Object Threads -Sum).Sum
    }
}

# Crash history, cached on its own slow cycle. The event log is the one expensive read
# here, and it changes about as often as the machine dies.
$script:Crashes = $null
$script:CrashesAt = $null
$CRASH_TTL_SECS = 300

function Get-Crashes {
    param([switch]$Force)
    $stale = -not $script:CrashesAt -or ((Get-Date) - $script:CrashesAt).TotalSeconds -gt $CRASH_TTL_SECS
    if (-not ($Force -or $stale)) { return $script:Crashes }

    $since = (Get-Date).AddDays(-$Days)
    # List[psobject], not List[object]: on PowerShell 7.6 the array subexpression @($list)
    # throws "Argument types do not match" against a List[object], and every consumer here
    # wraps its result in @(). Verified on 7.6.6; List[string] and List[psobject] are fine.
    $out = New-Object System.Collections.Generic.List[psobject]

    # 41 Kernel-Power: froze or lost power, no clean shutdown. 1001: blue screen.
    # 6008: the shutdown before this boot was unexpected.
    try {
        $sys = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $since } -MaxEvents 40 -ErrorAction Stop
        foreach ($e in $sys) {
            $what = switch ([int]$e.Id) {
                41   { 'hard reset or power loss (no clean shutdown)' }
                1001 { 'blue screen (bugcheck)' }
                6008 { 'previous shutdown was unexpected' }
                default { "system event $($e.Id)" }
            }
            $out.Add([pscustomobject]@{ Time = $e.TimeCreated; Kind = 'system'; Id = [int]$e.Id; What = $what })
        }
    } catch {}

    # App crashes and hangs over the same window, so a Node death lines up with a reboot.
    try {
        $app = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $since } -MaxEvents 80 -ErrorAction Stop
        foreach ($e in $app) {
            $who = if ($e.Properties.Count -gt 0) { [string]$e.Properties[0].Value } else { 'unknown' }
            $kind = if ([int]$e.Id -eq 1002) { 'hang' } else { 'crash' }
            $out.Add([pscustomobject]@{ Time = $e.TimeCreated; Kind = 'app'; Id = [int]$e.Id; What = "$who $kind" })
        }
    } catch {}

    $script:Crashes = @($out | Sort-Object Time -Descending)
    $script:CrashesAt = Get-Date
    return $script:Crashes
}

function Get-Snapshot {
    return @{
        Time  = Get-Date
        Mem   = Get-MemStats
        Cpu   = Get-CpuStats
        Disks = @(Get-DiskStats)
        Proc  = Get-ProcStats
    }
}

# --- the log ---------------------------------------------------------------------

function Write-Sample($s) {
    $dir = Split-Path $script:LogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cDrive = @($s.Disks | Where-Object { $_.Drive -eq 'C:' })[0]
    $worst = @($s.Proc.Groups)[0]
    $hog = @($s.Proc.Singles)[0]
    $row = [ordered]@{
        t        = $s.Time.ToString('o')
        ram      = [math]::Round($s.Mem.RamPct, 1)
        ramUsedG = [math]::Round($s.Mem.RamUsedGB, 2)
        commit   = if ($null -ne $s.Mem.CommitPct) { [math]::Round($s.Mem.CommitPct, 1) } else { $null }
        cpu      = if ($null -ne $s.Cpu.Pct) { [math]::Round($s.Cpu.Pct, 0) } else { $null }
        cFreeG   = if ($cDrive) { [math]::Round($cDrive.FreeGB, 1) } else { $null }
        procs    = $s.Proc.Total
        node     = $s.Proc.NodeCount
        nodeG    = [math]::Round($s.Proc.NodeWsGB, 2)
        handles  = $s.Proc.Handles
        topName  = if ($worst) { $worst.Label } else { $null }
        topG     = if ($worst) { [math]::Round($worst.WsGB, 2) } else { $null }
        hogName  = if ($hog) { $hog.Desc } else { $null }
        hogG     = if ($hog) { [math]::Round($hog.WsGB, 2) } else { $null }
    }
    Add-Content -Path $script:LogPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8

    # Keep the log from growing without limit. A sample is about 200 bytes, so 8MB is
    # months of history at one a minute, and trimming to the last 20k lines still leaves
    # whatever window matters for the crash actually being chased.
    try {
        if ((Get-Item $script:LogPath).Length -gt 8MB) {
            $keep = Get-Content $script:LogPath -Tail 20000
            Set-Content -Path $script:LogPath -Value $keep -Encoding utf8
        }
    } catch {}
}

function Read-Samples($hours) {
    if (-not (Test-Path $script:LogPath)) { return @() }
    $cut = (Get-Date).AddHours(-$hours)
    $out = New-Object System.Collections.Generic.List[psobject]
    foreach ($line in @(Get-Content $script:LogPath -Tail 40000)) {
        if (-not "$line".Trim()) { continue }
        try {
            $o = $line | ConvertFrom-Json
            $t = [datetime]::Parse($o.t)
            if ($t -ge $cut) { $out.Add([pscustomobject]@{ T = $t; S = $o }) }
        } catch {}
    }
    return @($out)
}

# --- render ----------------------------------------------------------------------

function Fmt-Uptime($since) {
    if (-not $since) { return '?' }
    $ts = (Get-Date) - $since
    if ($ts.TotalDays -ge 1) { return '{0}d {1}h' -f [int]$ts.TotalDays, $ts.Hours }
    if ($ts.TotalHours -ge 1) { return '{0}h {1}m' -f [int]$ts.TotalHours, $ts.Minutes }
    return '{0}m' -f [int]$ts.TotalMinutes
}

# Every meter here reads "used", and tui.ps1 colours high as good because it was written
# for headroom bars. Feed it the headroom so one colour language holds across dash and
# vitals: green is fine, red is trouble.
function Used-Color($pct) {
    if ($null -eq $pct) { return $C.grey }
    return Pct-Color (100 - $pct)
}

function Render-Meter($label, $pct, $barW, $tail) {
    $lab = Pad-To $label 9
    $col = Used-Color $pct
    $bar = Render-Bar $pct $null $barW $col
    $pctTxt = if ($null -ne $pct) { '{0,3}%' -f [int]$pct } else { '  ?%' }
    "$lab $bar $col$pctTxt$($C.reset) $($C.grey)$tail$($C.reset)"
}

function Get-Concerns($s, $crashes) {
    $out = @()
    if ($s.Mem.RamPct -ge 90) { $out += 'RAM {0}% used' -f [int]$s.Mem.RamPct }
    if ($null -ne $s.Mem.CommitPct -and $s.Mem.CommitPct -ge 90) { $out += 'commit {0}% used' -f [int]$s.Mem.CommitPct }
    # Free space in GB, not percent. A 1TB drive at 93% still has 65GB, which is fine,
    # and a percent rule cries wolf on it every single run.
    foreach ($d in $s.Disks) {
        if ($d.FreeGB -lt 25) { $out += '{0} only {1} free' -f $d.Drive, (Fmt-GB $d.FreeGB) }
    }
    if ($null -ne $s.Cpu.Pct -and $s.Cpu.Pct -ge 92) { $out += 'CPU pinned at {0}%' -f [int]$s.Cpu.Pct }
    if ($s.Proc.NodeCount -ge 60) { $out += '{0} node processes' -f $s.Proc.NodeCount }
    if ($s.Proc.Handles -ge 400000) { $out += '{0} open handles' -f (Fmt-Count $s.Proc.Handles) }
    $hog = @($s.Proc.Singles)[0]
    if ($hog -and $hog.WsGB -ge 6) { $out += '{0} holding {1}' -f $hog.Desc, (Fmt-GB $hog.WsGB) }
    $recent = @($crashes | Where-Object { $_.Kind -eq 'system' -and $_.Time -ge (Get-Date).AddHours(-24) })
    if ($recent.Count) { $out += 'hard crash in the last 24h' }
    return $out
}

function Render-Vitals {
    $lay = Get-Layout -Width $Width
    $s = Get-Snapshot
    $crashes = @(Get-Crashes)
    $barW = if ($lay.Width -ge 100) { 24 } else { 14 }
    $ramTotal = $s.Mem.RamTotalGB
    $lines = New-Object System.Collections.Generic.List[string]

    # No blank separators and no section banners. On a terminal with tall line spacing
    # every line is expensive, and the whole point of this screen is to fit in one look.
    # The row labels (ram, commit, cpu, C:) already say what each block is.

    # Line 1 carries the counts that used to need a PROCESSES banner of their own.
    $head = "$($C.bold)vitals$($C.reset) $($C.grey)$($G.middot)$($C.reset) $(Get-Date -Format 'HH:mm:ss')" +
            "$($C.grey) $($G.middot) up $(Fmt-Uptime $s.Mem.UptimeSince)" +
            " $($G.middot) $($s.Proc.Total) procs $($G.middot) $($s.Proc.NodeCount) node $(Fmt-GB $s.Proc.NodeWsGB)" +
            " $($G.middot) $(Fmt-Count $s.Proc.Handles) handles$($C.reset)"
    $lines.Add($head)

    $concerns = @(Get-Concerns $s $crashes)
    if ($concerns.Count) {
        # Truncate rather than wrap. A wrapped headline costs a whole extra line and the
        # detail is in the blocks below anyway.
        $lines.Add("$($C.red)$($G.dot) $(Fit ($concerns -join "  $($G.middot) ") ($lay.Width - 3))$($C.reset)")
    } else {
        $lines.Add("$($C.green)$($G.ok) nothing is close to the edge$($C.reset)")
    }

    # --- meters: memory, cpu, disks, all in one block
    $lines.Add((Render-Meter 'ram' $s.Mem.RamPct $barW ("{0}/{1} used, {2} free" -f (Fmt-GB $s.Mem.RamUsedGB), (Fmt-GB $s.Mem.RamTotalGB), (Fmt-GB $s.Mem.RamFreeGB))))
    $headroom = $s.Mem.CommitTotalGB - $s.Mem.CommitUsedGB
    $commitTail = "{0}/{1} promised, {2} left" -f (Fmt-GB $s.Mem.CommitUsedGB), (Fmt-GB $s.Mem.CommitTotalGB), (Fmt-GB $headroom)
    # Normal file-cache reads push paging into the hundreds all day, so it only earns a
    # mention well above that - and as a tail on a line that already exists, not a new one.
    if ($null -ne $s.Mem.PagesPerSec -and $s.Mem.PagesPerSec -ge 4000) {
        $commitTail += " $($G.middot) paging {0:N0}/s" -f $s.Mem.PagesPerSec
    }
    $lines.Add((Render-Meter 'commit' $s.Mem.CommitPct $barW $commitTail))

    $cpuTail = if ($null -ne $s.Cpu.Queue) { "{0} cores, {1} waiting" -f $script:Cores, $s.Cpu.Queue } else { "{0} cores" -f $script:Cores }
    $hot = @($s.Proc.Groups | Sort-Object Cpu -Descending | Where-Object { $_.Cpu -ge 1 } | Select-Object -First 3)
    if ($hot.Count) { $cpuTail += " $($G.middot) " + (($hot | ForEach-Object { '{0} {1:N0}%' -f (Fit $_.Label 18), $_.Cpu }) -join ', ') }
    $lines.Add((Render-Meter 'cpu' $s.Cpu.Pct $barW $cpuTail))

    foreach ($d in $s.Disks) {
        $lines.Add((Render-Meter $d.Drive $d.UsedPct $barW ("{0} free of {1}" -f (Fmt-GB $d.FreeGB), (Fmt-GB $d.TotalGB))))
    }

    # --- processes. Two percent columns side by side need naming, or "12%  18%" reads
    # as nonsense, so this one header line stays.
    $lines.Add("$($C.grey)$(Pad-To 'process' 24) $('{0,4}' -f 'n') $('{0,7}' -f 'ram') $('{0,5}' -f 'share') $('{0,5}' -f 'cpu')$($C.reset)")
    foreach ($g in @($s.Proc.Groups | Select-Object -First $Top)) {
        $nm = Pad-To (Fit $g.Label 24) 24
        $cnt = '{0,4}' -f $g.Count
        $ram = '{0,7}' -f (Fmt-GB $g.WsGB)
        # Share of installed RAM. Working sets double-count pages that processes share, so
        # this column sums to more than 100% - it ranks who is heavy, it is not a budget.
        $share = if ($ramTotal -gt 0) { 100 * $g.WsGB / $ramTotal } else { 0 }
        $shareTxt = if ($share -ge 0.5) { '{0:N0}%' -f $share } else { '<1%' }
        $cpuTxt = if ($g.Cpu -ge 1) { '{0,4:N0}%' -f $g.Cpu } else { '    -' }
        $ramCol = if ($g.WsGB -ge 8) { $C.yellow } else { $C.white }
        $shareCol = if ($share -ge 10) { $C.yellow } else { $C.grey }
        $lines.Add("$nm $($C.grey)$cnt$($C.reset) $ramCol$ram$($C.reset) $shareCol$('{0,5}' -f $shareTxt)$($C.reset) $($C.grey)$cpuTxt$($C.reset)")
    }
    # The heaviest single processes, marked with a glyph instead of a banner line.
    foreach ($b in @($s.Proc.Singles | Where-Object { $_.WsGB -ge 1 } | Select-Object -First 3)) {
        $col = if ($b.WsGB -ge 6) { $C.red } elseif ($b.WsGB -ge 3) { $C.yellow } else { $C.white }
        $share = if ($ramTotal -gt 0) { 100 * $b.WsGB / $ramTotal } else { 0 }
        # 13 arguments need indexes 0..12. An off-by-one here silently prints a colour code
        # in a number slot and the raw double in the next, which is how it failed before.
        $lines.Add(("{0}{1}{2} {3} {4}{5,7}{6} {7}{8,4:N0}%{9} {10}pid {11}{12}" -f
            $C.grey, $G.dot, $C.reset, (Pad-To (Fit $b.Desc 22) 22),
            $col, (Fmt-GB $b.WsGB), $C.reset,
            $C.grey, $share, $C.reset,
            $C.grey, $b.Pid, $C.reset))
    }

    # --- crashes. System events get a line each because the time matters. App crashes
    # collapse to one line, because which app and how often is all you need from them.
    $sysCrashes = @($crashes | Where-Object { $_.Kind -eq 'system' })
    $appCrashes = @($crashes | Where-Object { $_.Kind -eq 'app' })
    if (-not $sysCrashes.Count -and -not $appCrashes.Count) {
        $lines.Add("$($C.grey)crashes $($G.middot) last $Days d$($C.reset)  $($C.green)$($G.ok) none logged$($C.reset)")
    } else {
        $lines.Add("$($C.grey)crashes $($G.middot) last $Days d$($C.reset)")
    }
    foreach ($e in @($sysCrashes | Select-Object -First 3)) {
        $lines.Add("$($C.red)$($G.dot)$($C.reset) $($e.Time.ToString('MM-dd HH:mm'))  $(Fit $e.What ($lay.Width - 18))")
    }
    if ($appCrashes.Count) {
        $apps = @($appCrashes | Group-Object What | Sort-Object Count -Descending | Select-Object -First 5 |
                  ForEach-Object { '{0}x {1}' -f $_.Count, ($_.Name -replace '\.exe ', ' ') })
        $lines.Add("$($C.yellow)$($G.dot)$($C.reset) $($C.grey)apps: $(Fit ($apps -join ', ') ($lay.Width - 9))$($C.reset)")
    }

    if ($Watch) { Write-Sample $s }

    $w = ($lines | ForEach-Object { Vis-Len $_ } | Measure-Object -Maximum).Maximum
    return @($lines | ForEach-Object { Pad-To $_ $w })
}

function Render-History {
    $samples = Read-Samples $Hours
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$($C.bold)vitals history$($C.reset) $($C.grey)$($G.middot) last $Hours h $($G.middot) $($samples.Count) samples$($C.reset)")
    $lines.Add('')
    if (-not $samples.Count) {
        $lines.Add("$($C.grey)Nothing logged yet. Run 'vitals -Log' on a schedule, or leave 'vitals -Watch'$($C.reset)")
        $lines.Add("$($C.grey)open, and the history builds itself.$($C.reset)")
        return $lines
    }

    $lines.Add("$($C.grey)hour      ram%  commit%   cpu%  node   C: free  biggest$($C.reset)")
    foreach ($h in @($samples | Group-Object { $_.T.ToString('MM-dd HH') } | Sort-Object Name)) {
        $ram    = (@($h.Group | ForEach-Object { $_.S.ram })    | Measure-Object -Maximum).Maximum
        $commit = (@($h.Group | ForEach-Object { $_.S.commit }) | Measure-Object -Maximum).Maximum
        $cpu    = (@($h.Group | ForEach-Object { $_.S.cpu })    | Measure-Object -Maximum).Maximum
        $node   = (@($h.Group | ForEach-Object { $_.S.node })   | Measure-Object -Maximum).Maximum
        $free   = (@($h.Group | ForEach-Object { $_.S.cFreeG }) | Measure-Object -Minimum).Minimum
        # hogName is the single fattest process that hour. Older samples only carry the
        # group name, so fall back rather than showing a blank column for them.
        $peak   = @($h.Group | Sort-Object { $_.S.hogG } -Descending)[0].S
        $top    = if ($peak.hogName) { '{0} {1}' -f $peak.hogName, (Fmt-GB $peak.hogG) } else { $peak.topName }
        $rc = Used-Color $ram
        $cc = Used-Color $commit
        $lines.Add(("{0}  {1}{2,5:N0}{3}  {4}{5,7:N0}{6}  {7,5:N0}  {8,4}  {9,8}  {10}" -f `
            $h.Name, $rc, $ram, $C.reset, $cc, $commit, $C.reset,
            $cpu, $node, (Fmt-GB $free), (Fit $top 30)))
    }
    $lines.Add('')
    $lines.Add("$($C.grey)Each row is that hour's worst reading, so a crash lines up with what caused it.$($C.reset)")
    return $lines
}

# --- main -------------------------------------------------------------------------

if ($Log) {
    Write-Sample (Get-Snapshot)
    exit 0
}

if ($Json) {
    $s = Get-Snapshot
    $cr = @(Get-Crashes)
    [pscustomobject]@{
        Time      = $s.Time.ToString('o')
        Memory    = $s.Mem
        Cpu       = $s.Cpu
        Disks     = $s.Disks
        Processes = @{
            Total   = $s.Proc.Total
            Node    = $s.Proc.NodeCount
            NodeGB  = [math]::Round($s.Proc.NodeWsGB, 2)
            Handles = $s.Proc.Handles
            Threads = $s.Proc.Threads
            Groups  = @($s.Proc.Groups | Select-Object -First $Top)
        }
        Crashes   = $cr
        Concerns  = @(Get-Concerns $s $cr)
    } | ConvertTo-Json -Depth 6
    exit 0
}

if ($History) { Render-History; exit 0 }

$secs = Parse-Every $Every
$runOnce = $Once -or -not $Watch

if (-not $runOnce) {
    # Same reason dash refuses: without a real console there is no q to press and no
    # alternate screen to hand back, so the loop would spin forever in a pipe.
    if ([Console]::IsOutputRedirected) {
        # -ErrorAction Continue is load-bearing: $ErrorActionPreference is Stop at the top
        # of this file, so a plain Write-Error throws and the exit below never runs, which
        # hands the caller a terminating error instead of the promised exit code. This way
        # the message still goes through the error stream, where 2>&1 can catch it.
        Write-Error '-Watch needs a real terminal. For a single frame use vitals (no -Watch), or vitals -Once.' -ErrorAction Continue
        exit 1
    }
    $canPoll = $true
    try { $null = [Console]::KeyAvailable } catch { $canPoll = $false }

    Get-Crashes -Force | Out-Null
    Write-Host -NoNewline "$ESC[?1049h$ESC[?25l"
    $last = ''
    try {
        while ($true) {
            $text = (Render-Vitals) -join "`n"
            $last = $text
            $quit = if ($canPoll) { 'press q to quit' } else { 'press Ctrl+C to quit' }
            $foot = "$($C.grey)refreshes every $Every $($G.middot) each frame is logged $($G.middot) updated $(Get-Date -Format 'HH:mm:ss') $($G.middot) $quit$($C.reset)"
            Write-Host -NoNewline "$ESC[H$ESC[2J"
            Write-Host $text
            Write-Host $foot
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

Render-Vitals
# Every other path in this file exits explicitly, and a monitoring tool that gets called
# from a script should always leave a real exit code behind rather than a stale one.
exit 0
