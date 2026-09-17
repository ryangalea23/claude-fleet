# Shared settings for every tool in this repo: which accounts exist and where state lives.
#
# Dot-source this, then call Get-FleetConfig once.
#
#   . "$PSScriptRoot\lib\config.ps1"
#   $cfg = Get-FleetConfig
#   foreach ($a in $cfg.Accounts) { $a.Name; $a.ClaudeDir; $a.CodexDir }
#
# The file is config.json at the repo root (or wherever CLAUDE_FLEET_CONFIG points). With
# no file at all you get one account named "default" that uses the standard ~/.claude and
# ~/.codex, which is what a single-account install already has.
#
# An account can be a bare name or an object:
#
#   "accounts": [
#     "work",                                       first account: ~/.claude and ~/.codex
#     "personal",                                   later ones: ~/.claude-personal, ~/.codex-personal
#     { "name": "lab", "claudeDir": "D:/agents/claude-lab", "codexDir": "D:/agents/codex-lab" }
#   ]
#
# Other keys, all optional:
#   stateDir    where hooks and dashboards keep state (default ~/.claude/fleet).
#               The CLAUDE_FLEET_STATE_DIR environment variable overrides it.
#   lanesDir    where codex-lane keeps lane folders (default ~/.claude/codex-lanes)
#   handoffDir  where handoff writes hand-off files (default ~/.claude/handoffs)
#   vitalsLog   the vitals sample log (default ~/.claude/vitals/samples.jsonl)
#   snapshotTaskName  the Task Scheduler name snapshot -Install uses (default claude-fleet-snapshot)
#   launch      how to start a CLI as an account in printed commands, e.g. "{vendor}-{account}"
#               when you have claude-work / codex-work wrapper functions (profile.ps1 makes
#               them). Without it, commands set CLAUDE_CONFIG_DIR / CODEX_HOME inline.
#   codexModels short names codex-lane accepts for -Model, e.g. { "fast": "gpt-5-mini" }

function Expand-FleetPath([string]$p) {
    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq '~') { $p = $HOME }
    elseif ($p -match '^~[\\/]') { $p = Join-Path $HOME $p.Substring(2) }
    return ($p -replace '/', '\').TrimEnd('\')
}

function Get-FleetConfig {
    $root = Split-Path $PSScriptRoot -Parent
    $path = if ($env:CLAUDE_FLEET_CONFIG) { $env:CLAUDE_FLEET_CONFIG } else { Join-Path $root 'config.json' }

    $raw = $null
    if (Test-Path -LiteralPath $path) {
        try { $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
        catch { throw "could not read $path as JSON: $($_.Exception.Message)" }
    } else {
        $path = $null
    }

    $defaultClaude = Join-Path $HOME '.claude'
    $defaultCodex = Join-Path $HOME '.codex'

    $list = if ($raw -and $raw.accounts) { @($raw.accounts) } else { @('default') }
    $accounts = [System.Collections.Generic.List[psobject]]::new()
    $i = 0
    foreach ($entry in $list) {
        $name = if ($entry -is [string]) { $entry } else { $entry.name }
        if (-not $name -or $name -notmatch '^[A-Za-z0-9_-]+$') {
            throw "config: account names may only use letters, digits, _ and - (got '$name')"
        }
        $claude = if ($entry -isnot [string] -and $entry.claudeDir) { Expand-FleetPath $entry.claudeDir }
                  elseif ($i -eq 0) { $defaultClaude } else { Join-Path $HOME ".claude-$name" }
        $codex = if ($entry -isnot [string] -and $entry.codexDir) { Expand-FleetPath $entry.codexDir }
                 elseif ($i -eq 0) { $defaultCodex } else { Join-Path $HOME ".codex-$name" }
        $accounts.Add([pscustomobject]@{
            Name      = $name
            ClaudeDir = $claude
            CodexDir  = $codex
            # The CLIs treat an unset variable as "use the default home". Setting it, even to
            # the default path, is not the same thing: Codex's app-server returns no threads
            # at all when CODEX_HOME is set. So the default dir means "leave the variable unset".
            ClaudeEnv = if ($claude -ieq $defaultClaude) { $null } else { $claude }
            CodexEnv  = if ($codex -ieq $defaultCodex) { $null } else { $codex }
        })
        $i++
    }
    $dupes = @($accounts | Group-Object Name | Where-Object Count -gt 1)
    if ($dupes) { throw "config: account '$($dupes[0].Name)' is listed twice" }

    $state = if ($env:CLAUDE_FLEET_STATE_DIR) { Expand-FleetPath $env:CLAUDE_FLEET_STATE_DIR }
             elseif ($raw -and $raw.stateDir) { Expand-FleetPath $raw.stateDir }
             else { Join-Path $HOME '.claude\fleet' }

    $models = @{}
    if ($raw -and $raw.codexModels) {
        foreach ($p in $raw.codexModels.PSObject.Properties) { $models[$p.Name] = [string]$p.Value }
    }

    return [pscustomobject]@{
        Path        = $path
        Accounts    = $accounts
        StateDir    = $state
        LanesDir    = if ($raw -and $raw.lanesDir) { Expand-FleetPath $raw.lanesDir } else { Join-Path $HOME '.claude\codex-lanes' }
        HandoffDir  = if ($raw -and $raw.handoffDir) { Expand-FleetPath $raw.handoffDir } else { Join-Path $HOME '.claude\handoffs' }
        VitalsLog   = if ($raw -and $raw.vitalsLog) { Expand-FleetPath $raw.vitalsLog } else { Join-Path $HOME '.claude\vitals\samples.jsonl' }
        SnapshotTaskName = if ($raw -and $raw.snapshotTaskName) { [string]$raw.snapshotTaskName } else { 'claude-fleet-snapshot' }
        Launch      = if ($raw -and $raw.launch) { [string]$raw.launch } else { $null }
        CodexModels = $models
    }
}

# Account names cannot go in a ValidateSet, because they come from a file. Check them here
# instead, with an error that lists what is actually configured.
function Get-FleetAccount($cfg, [string]$name) {
    $a = $cfg.Accounts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $a) {
        $known = ($cfg.Accounts | ForEach-Object Name) -join ', '
        $where = if ($cfg.Path) { $cfg.Path } else { 'no config.json, so only the default account exists' }
        # $name is whatever the caller typed, so drop control characters before echoing it.
        $shown = $name -replace '[\x00-\x1F\x7F-\x9F]', ' '
        throw "unknown account '$shown'. Configured: $known ($where)"
    }
    return $a
}

# The command a person pastes to run a CLI as one account, e.g. "claude-work" or
# "`$env:CLAUDE_CONFIG_DIR='C:\Users\me\.claude-work'; claude".
function Get-LaunchCommand($cfg, $account, [ValidateSet('claude', 'codex')][string]$vendor) {
    if ($cfg.Launch) { return ($cfg.Launch -replace '\{vendor\}', $vendor -replace '\{account\}', $account.Name) }
    $var = if ($vendor -eq 'claude') { 'CLAUDE_CONFIG_DIR' } else { 'CODEX_HOME' }
    $val = if ($vendor -eq 'claude') { $account.ClaudeEnv } else { $account.CodexEnv }
    if (-not $val) { return $vendor }
    return "`$env:$var='$($val -replace "'", "''")'; $vendor"
}
