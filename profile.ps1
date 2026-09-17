# Dot-source this from your PowerShell profile to get short commands for every tool:
#
#   . C:\path\to\claude-fleet\profile.ps1
#
# It also defines claude-<account> and codex-<account> for each account in config.json, so
# you can start either CLI as a given account. Set "launch": "{vendor}-{account}" in
# config.json to have snapshot and handoff print those names in their commands.

$global:ClaudeFleetRoot = $PSScriptRoot

function global:ai-usage        { & "$global:ClaudeFleetRoot\ai-usage.ps1" @args }
function global:fleet           { & "$global:ClaudeFleetRoot\fleet.ps1" @args }
function global:dash            { & "$global:ClaudeFleetRoot\dash.ps1" @args }
function global:vitals          { & "$global:ClaudeFleetRoot\vitals.ps1" @args }
function global:snapshot        { & "$global:ClaudeFleetRoot\snapshot.ps1" @args }
function global:resume-sessions { & "$global:ClaudeFleetRoot\snapshot.ps1" -Restore @args }
function global:handoff         { & "$global:ClaudeFleetRoot\handoff.ps1" @args }
function global:codex-lane      { & "$global:ClaudeFleetRoot\codex-lane.ps1" @args }

# Run a CLI with one account's config dir, then put the variable back the way it was.
# Uses the env: drive rather than [Environment]::SetEnvironmentVariable, which turns $null
# into an empty string, and an empty CLAUDE_CONFIG_DIR makes Claude Code look in the cwd.
function global:Invoke-AsAccount($var, $dir, $exe, $rest) {
    $old = (Get-Item "env:$var" -ErrorAction SilentlyContinue).Value
    $set = { param($v) if ($v) { Set-Item "env:$var" $v } else { Remove-Item "env:$var" -ErrorAction SilentlyContinue } }
    try { & $set $dir; & $exe @rest }
    finally { & $set $old }
}

. "$global:ClaudeFleetRoot\lib\config.ps1"
try {
    foreach ($a in (Get-FleetConfig).Accounts) {
        $claudeDir = if ($a.ClaudeEnv) { "'$($a.ClaudeEnv -replace "'", "''")'" } else { '$null' }
        $codexDir = if ($a.CodexEnv) { "'$($a.CodexEnv -replace "'", "''")'" } else { '$null' }
        Invoke-Expression "function global:claude-$($a.Name) { Invoke-AsAccount CLAUDE_CONFIG_DIR $claudeDir claude `$args }"
        Invoke-Expression "function global:codex-$($a.Name) { Invoke-AsAccount CODEX_HOME $codexDir codex `$args }"
    }
} catch {
    Write-Warning "claude-fleet: $($_.Exception.Message)"
}
