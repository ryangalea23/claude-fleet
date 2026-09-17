# snapshot - remember what was open, so a restart is not amnesia.
#
# The problem: the terminal closes on reboot and every session goes with it. The transcripts and
# hook state survive on disk, but nothing records WHICH sessions were live or how to get
# back into them, so you are left guessing from a folder of session ids.
#
# This writes that list. It runs on a schedule so the answer is already on disk when the
# machine dies - a snapshot you have to remember to take is no use for a crash.
#
#   snapshot            take one now
#   snapshot -Restore   show the last snapshot with a resume command per session
#   snapshot -Restore -All   include sessions that had already finished
#   snapshot -Install   register the scheduled task (every 5 minutes, Windows only)
#   snapshot -Demo      show the restore view for made-up sessions from demo/fixture.json
#
# Resume is `claude --resume <id>` / `codex resume <id>`, run from the session's own cwd
# and as the right account, because a session belongs to one account. Set "launch" in
# config.json to print your own wrapper commands (see lib/config.ps1).

param(
    [switch]$Restore,
    [switch]$All,
    [switch]$Install,
    [switch]$Ascii,
    [int]$Keep = 48,
    # Show the restore view for made-up sessions. Reads and writes nothing on this machine.
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\config.ps1"
$FleetCfg = Get-FleetConfig
$accounts = $FleetCfg.Accounts
$SNAP_DIR = Join-Path $FleetCfg.StateDir 'snapshots'
$LATEST = Join-Path $SNAP_DIR 'latest.json'

# --- install -----------------------------------------------------------------

if ($Install) {
    $ps = (Get-Process -Id $PID).Path
    $task = 'ClaudeFleetSnapshot'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -File `"$PSCommandPath`""
    # Every 5 minutes, indefinitely. RepetitionDuration of MaxValue means "forever"; a
    # finite duration silently stops repeating, which is the classic way these tasks die.
    # NOT [TimeSpan]::MaxValue - Task Scheduler rejects it as out of range
    # ("Duration:P99999999DT23H59M59S"). Ten years is indefinite in practice.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

    # Confirm by asking Task Scheduler, not by assuming the call worked. The first version
    # of this printed "registered" on a run that had thrown.
    $check = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    if (-not $check) { Write-Error "failed to register scheduled task '$task'"; exit 1 }
    Write-Host "registered '$task' - state $($check.State), every 5 minutes"
    Write-Host "remove it with: Unregister-ScheduledTask -TaskName $task -Confirm:`$false"
    return
}

# --- restore view ------------------------------------------------------------

if ($Restore -or $Demo) {
    . "$PSScriptRoot\lib\tui.ps1"
    Init-Tui -Ascii:$Ascii
    $C = Get-TuiColors; $G = Get-TuiGlyphs

    if (-not $Demo -and -not (Test-Path $LATEST)) {
        Write-Host "no snapshot yet. Run: snapshot   (or snapshot -Install to schedule it)"
        return
    }
    $snap = if ($Demo) {
        # Same shape as a real snapshot, with times stored relative to now.
        $fx = (Get-Content (Join-Path $PSScriptRoot 'demo\fixture.json') -Raw | ConvertFrom-Json).snapshot
        [pscustomobject]@{ takenAt = (Get-Date).AddMinutes(-$fx.takenMinutesAgo).ToString('o'); sessions = $fx.sessions }
    } else { Get-Content $LATEST -Raw | ConvertFrom-Json }
    $age = [int]((Get-Date) - [datetime]$snap.takenAt).TotalMinutes
    $rows = @($snap.sessions | Where-Object { $All -or $_.state -ne 'ended' })

    Write-Host ''
    Write-Host "$($C.bold)snapshot$($C.reset) $($C.grey)$($G.middot)$($C.reset) taken $age min ago $($C.grey)$($G.middot)$($C.reset) $($rows.Count) session(s)"
    Write-Host ''
    $i = 0
    foreach ($s in $rows) {
        $i++
        $dot = if ($s.state -eq 'waiting') { $C.red } elseif ($s.state -eq 'ended') { $C.grey } else { $C.blue }
        Write-Host ("{0}{1}{2} {3,2}  {4}{5}{6} {7}{8}{9} {10}" -f $dot, $G.dot, $C.reset, $i,
            $C.bold, $s.account, $C.reset, $C.grey, $s.where, $C.reset, (Fit $s.title 46))
        Write-Host ("     $($C.grey)$($s.resume)$($C.reset)")
    }
    Write-Host ''
    Write-Host "$($C.grey)paste a line to resume that session in this tab$($C.reset)"
    Write-Host ''
    return
}

# --- take a snapshot ---------------------------------------------------------

# Hook state is the crash-durable half: it is written as each session works, so it is
# already on disk when the machine dies. `claude agents --json` is the live half - it is
# the only thing that knows a session was actually OPEN rather than merely recent.
function Get-HookState($vendor) {
    $map = @{}
    $dir = Join-Path $FleetCfg.StateDir $vendor
    if (Test-Path $dir) {
        foreach ($f in (Get-ChildItem $dir -Filter *.json -EA SilentlyContinue)) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($j.sessionId) { $map[$j.sessionId] = $j }
        }
    }
    return $map
}

$claudeHooks = Get-HookState 'claude'
$codexHooks = Get-HookState 'codex'
$sessions = [System.Collections.ArrayList]@()

foreach ($account in $accounts) {
    $acct = $account.Name
    $prev = (Get-Item env:CLAUDE_CONFIG_DIR -EA SilentlyContinue).Value
    if (-not $account.ClaudeEnv) { Remove-Item env:CLAUDE_CONFIG_DIR -EA SilentlyContinue } else { Set-Item env:CLAUDE_CONFIG_DIR $account.ClaudeEnv }
    $agents = @()
    try { $agents = @((claude agents --json 2>&1) -join "`n" | ConvertFrom-Json) } catch { }
    if ($prev) { Set-Item env:CLAUDE_CONFIG_DIR $prev } else { Remove-Item env:CLAUDE_CONFIG_DIR -EA SilentlyContinue }

    foreach ($a in $agents) {
        $hk = $claudeHooks[$a.sessionId]
        $cwd = if ($hk -and $hk.cwd) { $hk.cwd } else { $a.cwd }
        # Belt and braces with the hook's own filter: never show a title that came from an
        # injected message, even if an older state file still has one stored.
        $hkAsk = if ($hk -and $hk.firstAsk -and $hk.firstAsk -notmatch '^\s*<') { $hk.firstAsk } else { $null }
        $title = if ($hkAsk) { $hkAsk } elseif ($a.name) { $a.name } else { '(no title)' }
        [void]$sessions.Add([ordered]@{
            vendor  = 'claude'
            account = $acct
            id      = $a.sessionId
            cwd     = $cwd
            where   = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }
            title   = ($title -replace '\s+', ' ').Trim()
            state   = if ($hk) { $hk.state } elseif ($a.status -eq 'busy') { 'working' } else { 'idle' }
            lastSeen = if ($hk -and $hk.updatedAt) { $hk.updatedAt } else { (Get-Date).ToString('o') }
            # Everything needed to get back in: the folder, the account, the session.
            resume  = "cd '$cwd'; $(Get-LaunchCommand $FleetCfg $account 'claude') --resume $($a.sessionId)"
        })
    }
}

# Codex has no live-session query on Windows, so recency is the only signal available.
foreach ($account in $accounts) {
    $acct = $account.Name
    $dir = $account.CodexDir
    $recent = Get-ChildItem "$dir\sessions" -Recurse -Filter *.jsonl -EA SilentlyContinue |
              Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-12) } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 8
    foreach ($f in $recent) {
        $id = if ($f.Name -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $Matches[1] } else { continue }
        $hk = $codexHooks[$id]
        $cwd = if ($hk -and $hk.cwd) { $hk.cwd } else { $null }
        $rollTitle = $null
        # Sessions that predate the hooks have no state file, and a row with no folder and
        # no title is useless for deciding whether to resume it. The rollout head carries
        # both as real fields, so read them rather than showing "?".
        if (-not $cwd -or -not ($hk -and $hk.firstAsk)) {
            try {
                foreach ($line in (Get-Content $f.FullName -TotalCount 40)) {
                    if ($line -notmatch '^\{') { continue }
                    $o = $line | ConvertFrom-Json
                    if (-not $cwd -and $o.payload.cwd) { $cwd = $o.payload.cwd }
                    if (-not $rollTitle -and $o.payload.type -eq 'message' -and $o.payload.role -eq 'user') {
                        $t = ($o.payload.content | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ' '
                        if ($t -and $t -notmatch '^\s*<') { $rollTitle = ($t -replace '\s+', ' ').Trim() }
                    }
                    if ($cwd -and $rollTitle) { break }
                }
            } catch { }
        }
        [void]$sessions.Add([ordered]@{
            vendor  = 'codex'
            account = $acct
            id      = $id
            cwd     = $cwd
            where   = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }
            title   = if ($hk -and $hk.firstAsk) { ($hk.firstAsk -replace '\s+', ' ').Trim() }
                      elseif ($rollTitle) { $rollTitle } else { '(codex session)' }
            state   = if ($hk) { $hk.state } else { 'unknown' }
            lastSeen = $f.LastWriteTime.ToString('o')
            resume  = if ($cwd) { "cd '$cwd'; $(Get-LaunchCommand $FleetCfg $account 'codex') resume $id" } else { "$(Get-LaunchCommand $FleetCfg $account 'codex') resume $id" }
        })
    }
}

New-Item -ItemType Directory -Force -Path $SNAP_DIR | Out-Null
$snap = [ordered]@{
    takenAt  = (Get-Date).ToString('o')
    host     = $env:COMPUTERNAME
    sessions = @($sessions)
}
$json = $snap | ConvertTo-Json -Depth 8

# Write then move, so a reader never catches a half-written snapshot.
$tmp = "$LATEST.tmp"
$json | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $LATEST -Force
$json | Set-Content -LiteralPath (Join-Path $SNAP_DIR ("{0}.json" -f (Get-Date -Format 'yyyy-MM-dd-HHmm'))) -Encoding UTF8

# Keep a rolling history: the latest file answers "what was open", the dated ones answer
# "what was open before I broke it".
Get-ChildItem $SNAP_DIR -Filter '20*.json' -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep |
    Remove-Item -Force -EA SilentlyContinue

Write-Host "snapshot: $($sessions.Count) session(s) -> $LATEST"
