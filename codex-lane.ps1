<#
codex-lane.ps1 - run a Codex CLI "lane" (a background Codex worker) that Claude can start,
check on, and keep talking to.

  start   -Name <lane> -PromptFile <file> -Account <account from config.json>
          -Model <alias or model id> -Effort low|medium|high|xhigh|max -Dir <folder>
          [-Sandbox read-only|workspace-write|danger-full-access] [-NoWait]
  resume  -Name <lane> (-Prompt "<text>" | -PromptFile <file>) [-Model ..] [-Effort ..] [-NoWait]
  status  -Name <lane> [-Wait]
  list

Codex runs as its own process, so whatever kills the calling agent's shell can't kill it.
start/resume wait for the turn to finish and print Codex's answer: run them with
run_in_background:true and Claude is woken when the turn ends. If that wait gets cut off,
Codex keeps going - run `status -Name <lane> -Wait` to wait again.
resume continues the same Codex session, so Codex remembers everything from earlier turns.
The worker is launched through WMI, outside the caller's process tree, so killing a background
start/status call does not kill Codex. If a worker dies without an exit code, status and list
report it as "died" and resume picks the lane up again.

Model aliases: luna, terra, sol and astra are built in. Add or override aliases with
"codexModels" in config.json, or pass a full model id.

Windows only: the worker is launched through WMI.

Lane files live in ~/.claude/codex-lanes/<lane>/ (set "lanesDir" in config.json to move them):
  meta.json, turn-N.prompt.md, turn-N.jsonl (live event log), turn-N.last.md (final answer),
  turn-N.err.txt, turn-N.pid, turn-N.exit
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('start', 'resume', 'status', 'list', 'run')][string]$Action,
  [string]$Name,
  [string]$PromptFile,
  [string]$Prompt,
  # Account names and model aliases come from config.json, so they are checked at runtime.
  [string]$Account,
  [string]$Model,
  [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$Effort,
  [string]$Dir,
  # workspace-write lets Codex edit files inside -Dir only. danger-full-access removes the
  # sandbox entirely (any file, any command, network) and must be asked for explicitly.
  [ValidateSet('read-only', 'workspace-write', 'danger-full-access')][string]$Sandbox = 'workspace-write',
  # Pass --dangerously-bypass-hook-trust to codex, so hooks in ~/.codex/hooks.json run in an
  # unattended lane. Off by default; lanes run fine without it, the hooks just do not fire.
  [switch]$BypassHookTrust,
  [switch]$NoWait,
  [switch]$Wait,
  [int]$Turn  # internal, used by 'run'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\config.ps1"
. "$PSScriptRoot\lib\tui.ps1"
$FleetCfg = Get-FleetConfig
$Root = $FleetCfg.LanesDir
$ModelIds = @{ luna = 'gpt-5.6-luna'; terra = 'gpt-5.6-terra'; sol = 'gpt-5.6-sol'; astra = 'gpt-6-astra' }
foreach ($k in $FleetCfg.CodexModels.Keys) { $ModelIds[$k] = $FleetCfg.CodexModels[$k] }
# An alias maps to its id; anything else is passed to codex as a model id unchanged.
function Resolve-Model([string]$m) { if ($ModelIds.ContainsKey($m)) { $ModelIds[$m] } else { $m } }

function Fail([string]$msg) { [Console]::Error.WriteLine("codex-lane: $msg"); exit 2 }

# Every value below ends up inside a cmd.exe /c line, where & | < > ^ and % mean something.
# Accept only what each value should look like, and fail before any process starts.
function Assert-ModelId([string]$m) {
  $id = Resolve-Model $m
  if ($id -notmatch '^[A-Za-z0-9._:-]+$') { Fail "model '$m' is not a valid model id (letters, digits, . _ : - only)" }
  return $id
}
function Assert-CmdPath([string]$what, [string]$p) {
  if ($p -match '["%\r\n]') { Fail "$what '$p' contains a character that is unsafe on a cmd.exe line (a double quote, a percent sign or a newline)" }
}

function Get-LaneDir {
  if (-not $Name) { Fail '-Name is required' }
  if ($Name -notmatch '^[A-Za-z0-9_-]+$') { Fail "lane name '$Name' may only use letters, digits, _ and -" }
  Join-Path $Root $Name
}
function Read-Meta([string]$d) {
  $f = Join-Path $d 'meta.json'
  if (-not (Test-Path $f)) { Fail "no lane named '$Name' (looked in $d)" }
  Get-Content $f -Raw | ConvertFrom-Json
}
function Write-Meta([string]$d, $m) { $m | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $d 'meta.json') }
function TurnFile([string]$d, [int]$t, [string]$suffix) { Join-Path $d "turn-$t.$suffix" }

function Get-SessionId([string]$d) {
  $log = TurnFile $d 1 'jsonl'
  if (-not (Test-Path $log)) { return $null }
  $first = Get-Content $log -TotalCount 1
  try { ($first | ConvertFrom-Json).thread_id } catch { $null }
}

function Read-Events([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  @(Get-Content $path | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
}

function Show-Progress([string]$d, [int]$t) {
  $events = Read-Events (TurnFile $d $t 'jsonl')
  $items = @($events | Where-Object { $_.type -eq 'item.completed' } | ForEach-Object { $_.item })
  $counts = ($items | Group-Object type | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
  "steps so far: $(if ($counts) { $counts } else { 'none yet' })"
  foreach ($i in ($items | Select-Object -Last 5)) {
    $text = if ($i.command) { $i.command } elseif ($i.text) { $i.text } else { '' }
    $text = ($text -replace '\s+', ' ')
    if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
    "  - [$($i.type)] $(Clean-Text $text)"
  }
  $doneIds = @($items | ForEach-Object { $_.id })
  foreach ($i in @($events | Where-Object { $_.type -eq 'item.started' -and $_.item.id -notin $doneIds } | ForEach-Object { $_.item })) {
    "  - [running now: $($i.type)] $(Clean-Text $i.command)"
  }
}

function Show-Tail([string]$path, [int]$chars) {
  if (-not (Test-Path $path)) { return }
  $s = Get-Content $path -Raw
  if (-not $s) { return }
  if ($s.Length -gt $chars) { $s = '...' + $s.Substring($s.Length - $chars) }
  # Codex output is untrusted: keep its lines, drop any escape sequences.
  Clean-Text $s -KeepLines
}

function Start-Turn([string]$d, [int]$t) {
  $argLine = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$PSCommandPath`" run -Name $Name -Turn $t"
  # Launch through WMI (Win32_Process.Create), not Start-Process. A Start-Process child belongs to
  # the caller's process tree / job object, so when Claude Code's memory watchdog kills a
  # background `start`/`status -Wait` call it killed the Codex worker too (four lanes once
  # died with their watchers this way). A WMI-created process has no parent in that tree.
  $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  $workerPid = $null
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -ErrorAction Stop -Arguments @{
      CommandLine      = "`"$pwsh`" $argLine"
      CurrentDirectory = $d
    }
    if ($r.ReturnValue -eq 0) { $workerPid = [int]$r.ProcessId }
  } catch { }
  if (-not $workerPid) {
    # Fallback keeps the lane usable if WMI is unavailable; it is NOT watchdog-proof.
    $proc = Start-Process pwsh -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $workerPid = $proc.Id
    Write-Warning "WMI launch failed; worker started as a child process and can die with its caller."
  }
  Set-Content (TurnFile $d $t 'pid') $workerPid
  "launched lane $Name turn $t (worker pid $workerPid)"
}

# True only while THIS turn's worker is running. Checks the process name and start time so a
# recycled PID belonging to some other process is not mistaken for the worker.
function Test-WorkerAlive([string]$d, [int]$t) {
  $pidFile = TurnFile $d $t 'pid'
  if (-not (Test-Path $pidFile)) { return $false }
  $p = Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue
  if (-not $p -or $p.ProcessName -ne 'pwsh') { return $false }
  $turn = @((Read-Meta $d).turns) | Where-Object { $_.n -eq $t }
  if ($turn -and $turn.started) {
    try { if ($p.StartTime -lt ([datetime]$turn.started).AddSeconds(-30)) { return $false } } catch { }
  }
  return $true
}

# Records that a turn's worker vanished without writing an exit code, so status/list/resume
# stop treating it as running. Exit code 137 = killed.
function Set-TurnDied([string]$d, [int]$t) {
  $exitFile = TurnFile $d $t 'exit'
  if (-not (Test-Path $exitFile)) {
    Set-Content (TurnFile $d $t 'died') (Get-Date).ToString('o')
    Set-Content $exitFile 137
  }
}

# Prints the state of the latest turn. With -Block, waits until it ends. Exit code = Codex's.
function Show-Status([string]$d, [bool]$block) {
  $m = Read-Meta $d
  $t = @($m.turns)[-1].n
  $exitFile = TurnFile $d $t 'exit'
  if ((Test-Path $exitFile) -and (Test-Path (TurnFile $d $t 'died'))) {
    "=== lane $Name turn ${t}: WORKER GONE earlier (recorded as died) - resume it to continue ==="
    Show-Progress $d $t
    exit 3
  }
  while (-not (Test-Path $exitFile)) {
    if (-not (Test-WorkerAlive $d $t)) {
      Start-Sleep -Seconds 2
      if (Test-Path $exitFile) { break }
      Set-TurnDied $d $t
      "=== lane $Name turn ${t}: WORKER GONE - it stopped without an exit code (crashed or killed). Recorded as died; resume it to continue. ==="
      Show-Progress $d $t
      Show-Tail (TurnFile $d $t 'err.txt') 3000
      exit 3
    }
    if (-not $block) {
      "=== lane $Name turn ${t}: RUNNING ==="
      Show-Progress $d $t
      exit 0
    }
    Start-Sleep -Seconds 10
  }
  $rc = [int](Get-Content $exitFile)
  $tm = @($m.turns)[-1]
  "=== lane $Name turn ${t}: DONE, exit $rc ($($tm.model)/$($tm.effort), account $($m.account), session $(Get-SessionId $d)) ==="
  Show-Tail (TurnFile $d $t 'last.md') 6000
  if ($rc -ne 0) { '--- stderr (tail) ---'; Show-Tail (TurnFile $d $t 'err.txt') 3000 }
  "--- to continue: codex-lane.ps1 resume -Name $Name -Prompt '<follow-up>' ---"
  exit $rc
}

switch ($Action) {
  'start' {
    foreach ($p in 'PromptFile', 'Account', 'Model', 'Effort', 'Dir') {
      if (-not (Get-Variable $p -ValueOnly)) { Fail "start needs -$p" }
    }
    $d = Get-LaneDir
    if (Test-Path $d) { Fail "lane '$Name' already exists - use resume, or pick a new name" }
    if (-not (Test-Path $PromptFile -PathType Leaf)) { Fail "prompt file not found: $PromptFile" }
    if (-not (Test-Path $Dir -PathType Container)) { Fail "folder not found: $Dir" }
    try { $acc = Get-FleetAccount $FleetCfg $Account } catch { Fail $_.Exception.Message }
    $null = Assert-ModelId $Model
    Assert-CmdPath 'folder' (Resolve-Path $Dir).Path
    Assert-CmdPath 'lane folder' $d
    New-Item -ItemType Directory -Force $d | Out-Null
    Copy-Item $PromptFile (TurnFile $d 1 'prompt.md')
    Write-Meta $d ([pscustomobject]@{
        name      = $Name
        account   = $Account
        codexHome = $acc.CodexEnv
        dir       = (Resolve-Path $Dir).Path
        sandbox   = $Sandbox
        bypassHookTrust = [bool]$BypassHookTrust
        created   = (Get-Date).ToString('o')
        turns     = @([pscustomobject]@{ n = 1; model = $Model; effort = $Effort; started = (Get-Date).ToString('o') })
      })
    Start-Turn $d 1
    if (-not $NoWait) { Show-Status $d $true }
  }

  'resume' {
    $d = Get-LaneDir
    $m = Read-Meta $d
    $last = @($m.turns)[-1]
    if (-not (Test-Path (TurnFile $d $last.n 'exit'))) {
      if (Test-WorkerAlive $d $last.n) { Fail "lane '$Name' turn $($last.n) is still running - wait for it first" }
      Set-TurnDied $d $last.n
      Write-Warning "turn $($last.n) worker had died without an exit code; recorded it as died and resuming."
    }
    if (-not (Get-SessionId $d)) { Fail "lane '$Name' has no Codex session id in turn-1.jsonl, so it can't be resumed" }
    if ([bool]$Prompt -eq [bool]$PromptFile) { Fail 'resume needs exactly one of -Prompt or -PromptFile' }
    if ($Model) { $null = Assert-ModelId $Model }
    if ($BypassHookTrust) { $m | Add-Member -Force NoteProperty bypassHookTrust $true }
    $t = $last.n + 1
    if ($PromptFile) {
      if (-not (Test-Path $PromptFile -PathType Leaf)) { Fail "prompt file not found: $PromptFile" }
      Copy-Item $PromptFile (TurnFile $d $t 'prompt.md')
    } else {
      Set-Content (TurnFile $d $t 'prompt.md') $Prompt
    }
    $m.turns = @($m.turns) + [pscustomobject]@{
      n       = $t
      model   = if ($Model) { $Model } else { $last.model }
      effort  = if ($Effort) { $Effort } else { $last.effort }
      started = (Get-Date).ToString('o')
    }
    Write-Meta $d $m
    Start-Turn $d $t
    if (-not $NoWait) { Show-Status $d $true }
  }

  'status' { Show-Status (Get-LaneDir) $Wait.IsPresent }

  'list' {
    if (-not (Test-Path $Root)) { 'no lanes yet'; exit 0 }
    Get-ChildItem $Root -Directory | Sort-Object LastWriteTime -Descending | ForEach-Object {
      $mf = Join-Path $_.FullName 'meta.json'
      if (-not (Test-Path $mf)) { return }
      $m = Get-Content $mf -Raw | ConvertFrom-Json
      $tm = @($m.turns)[-1]
      $exitFile = TurnFile $_.FullName $tm.n 'exit'
      $state = if (Test-Path (TurnFile $_.FullName $tm.n 'died')) { 'died (resumable)' }
               elseif (Test-Path $exitFile) { "done (exit $(Get-Content $exitFile))" }
               else {
                 $pf = TurnFile $_.FullName $tm.n 'pid'
                 $p = if (Test-Path $pf) { Get-Process -Id ([int](Get-Content $pf)) -ErrorAction SilentlyContinue }
                 if ($p -and $p.ProcessName -eq 'pwsh') { 'running' } else { 'died (resumable)' }
               }
      Clean-Text ('{0,-28} turn {1}  {2,-18} {3}/{4}  {5}  {6}' -f $m.name, $tm.n, $state, $tm.model, $tm.effort, $m.account, $m.dir)
    }
  }

  'run' {
    # Internal: the detached worker for one turn. Runs Codex and records its exit code.
    $d = Get-LaneDir
    $m = Read-Meta $d
    $tm = @($m.turns) | Where-Object { $_.n -eq $Turn }
    if (-not $tm) { Fail "turn $Turn not found in meta.json" }
    if ($m.codexHome) { $env:CODEX_HOME = $m.codexHome } else { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    $env:NODE_OPTIONS = '--max-old-space-size=4096'
    # Re-check everything that goes on the cmd line: meta.json is a file on disk and could
    # have been edited since start.
    $modelId = Assert-ModelId $tm.model
    if ($tm.effort -notin 'low', 'medium', 'high', 'xhigh', 'max') { Fail "effort '$($tm.effort)' is not allowed" }
    if ($m.sandbox -notin 'read-only', 'workspace-write', 'danger-full-access') { Fail "sandbox '$($m.sandbox)' is not allowed" }
    Assert-CmdPath 'folder' $m.dir
    Assert-CmdPath 'lane folder' $d
    # --dangerously-bypass-hook-trust, only when the lane was started with -BypassHookTrust:
    # a lane runs unattended, so there is nobody to approve a hook. Codex marks every
    # hooks.json entry untrusted until approved interactively, and the trust state cannot be
    # pre-seeded in the file. Without the flag the lane still runs; its hooks do not.
    $trust = if ($m.bypassHookTrust) { ' --dangerously-bypass-hook-trust' } else { '' }
    $common = "-m $modelId -c model_reasoning_effort=$($tm.effort) --skip-git-repo-check$trust --json"
    $cmd = if ($Turn -eq 1) {
      "codex exec $common -C `"$($m.dir)`" -s $($m.sandbox) --color never"
    } else {
      # 'exec resume' has no -C/-s flags: run from the lane folder and set the sandbox through config
      $sid = Get-SessionId $d
      if ("$sid" -notmatch '^[A-Za-z0-9-]+$') { Fail "session id '$sid' in turn-1.jsonl is not valid" }
      "codex exec resume $sid $common -c sandbox_mode=$($m.sandbox)"
    }
    $line = "$cmd -o `"$(TurnFile $d $Turn 'last.md')`" - < `"$(TurnFile $d $Turn 'prompt.md')`" > `"$(TurnFile $d $Turn 'jsonl')`" 2> `"$(TurnFile $d $Turn 'err.txt')`""
    $rc = 1
    try {
      $proc = Start-Process cmd.exe -ArgumentList "/d /c `"$line`"" -WorkingDirectory $m.dir -NoNewWindow -Wait -PassThru
      $rc = $proc.ExitCode
    } finally {
      Set-Content (TurnFile $d $Turn 'exit') $rc
    }
  }
}
