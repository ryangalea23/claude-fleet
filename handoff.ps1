# Hand the remaining work to a fresh Claude session in an account that still has headroom.
#
# Writes the hand-off to a file and prints the command to start it. The prompt stays short
# on purpose: passing a long hand-off on the command line hits Windows quoting and length
# limits, and a file survives a crash, which a pasted prompt does not.
#
#   handoff -Message "what is done, what is left, the next step"
#   handoff -File .\notes.md -To personal -Folder C:\repo
#   handoff -Message "..." -Launch      also open a terminal (see the -Launch note below)
#   handoff -Message "..." -DryRun      show what would be written and run, touch nothing
#
# -To auto (the default) picks the logged-in Claude account with the most week left.
# -To takes any account name from config.json (see lib/config.ps1).

param(
    [string]$Message,
    [string]$File,
    # 'auto', or an account name from config.json. Checked at runtime, because a
    # ValidateSet cannot read a config file.
    [string]$To = 'auto',
    [string]$Folder = (Get-Location).Path,
    [string]$Slug,
    [ValidateSet('auto', 'wt', 'tabby', 'window')]
    [string]$Terminal = 'auto',
    # Opening a terminal is off by default. Tabby's CLI cannot accept commands in the
    # released build (upstream issue 11658), so the only thing that reliably opens is a
    # Windows Terminal tab, which may not be where you work. Write the file, print the
    # command, let the person decide. -Launch opts back in.
    [switch]$Launch,
    # Print the hand-off and the command without writing the file or opening anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\config.ps1"
$FleetCfg = Get-FleetConfig

if (-not $Message -and -not $File) { throw 'Give me -Message "..." or -File <path>.' }
if ($Message -and $File) { throw 'Use -Message or -File, not both.' }
if (-not (Test-Path $Folder)) { throw "Folder not found: $Folder" }

# Terminal choice. Tabby 1.0.235's CLI was broken when this was written: every subcommand
# (run, open) dies in yargs with "mixin.stripAnsi is not a function" before doing
# anything, so it is not the default. Windows Terminal's CLI works and was verified to
# carry the command through. -Terminal tabby is kept for when Tabby ships a fix.
$tabby = "$env:LOCALAPPDATA\Programs\Tabby\Tabby.exe"
$hasWt = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
if ($Terminal -eq 'auto') { $Terminal = if ($hasWt) { 'wt' } elseif (Test-Path $tabby) { 'tabby' } else { 'window' } }
if ($Terminal -eq 'wt' -and -not $hasWt) { throw 'wt.exe not found; try -Terminal tabby or -Terminal window.' }
if ($Terminal -eq 'tabby' -and -not (Test-Path $tabby)) { throw "Tabby not found at $tabby" }

# --- pick the account ---------------------------------------------------------

function Pick-Account {
    $rows = & "$PSScriptRoot\ai-usage.ps1" -Json -ClaudeOnly | ConvertFrom-Json
    $live = @($rows | Where-Object { $_.Status -eq 'ok' -and $null -ne $_.HeadPct })
    if (-not $live) { throw 'No logged-in Claude account reported usage; pass -To explicitly.' }
    # Rank on the week window, not the headline: the headline is often the 5-hour session,
    # which refills on its own and says nothing about whether the account can carry a task.
    $best = $live | Sort-Object @{ e = {
        $w = $_.Windows | Where-Object { $_.Label -eq 'week' } | Select-Object -First 1
        if ($w) { [double]$w.Pct } else { [double]$_.HeadPct }
    } } -Descending | Select-Object -First 1
    return $best
}

if ($To -eq 'auto') {
    $pick = Pick-Account
    $account = $pick.Account
    $weekWin = $pick.Windows | Where-Object { $_.Label -eq 'week' } | Select-Object -First 1
    $why = if ($weekWin) { "$([int]$weekWin.Pct)% of the week left" } else { "$([int]$pick.HeadPct)% left" }
} else {
    $account = (Get-FleetAccount $FleetCfg $To).Name
    $why = 'chosen explicitly'
}

# --- write the hand-off file --------------------------------------------------

$dir = $FleetCfg.HandoffDir
if (-not $DryRun -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$body = if ($File) { Get-Content -Raw -LiteralPath $File } else { $Message }
if (-not $Slug) {
    $first = ($body -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    $Slug = ($first -replace '[^A-Za-z0-9 ]', '' -replace '\s+', '-').ToLower()
    if ($Slug.Length -gt 40) { $Slug = $Slug.Substring(0, 40) }
    if (-not $Slug) { $Slug = 'handoff' }
}
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmm'
$path = Join-Path $dir "$stamp-$Slug.md"

$header = @"
# Hand-off $stamp

- From: $env:USERNAME on $(hostname)
- Folder: $Folder
- Continuing in: account $account ($why)

"@
if (-not $DryRun) { Set-Content -LiteralPath $path -Value ($header + $body) -Encoding UTF8 }

# --- launch ------------------------------------------------------------------

# Short prompt, file does the talking. -NoExit keeps the tab alive if Claude exits, so a
# failed launch leaves a shell to read the error in rather than a tab that vanishes.
# Single-quote everything and double any embedded single quote. Nested double quotes do
# not survive the trip into pwsh; this does, and paths with spaces work.
# No semicolons in the prompt: Windows Terminal treats ';' as its own command separator
# and silently truncates there. That is why an earlier launch opened a tab that only ran
# Set-Location and never started Claude.
$prompt = "Read the hand-off at $path and continue that work. Pick up where it left off. Do not re-plan what is already done."
$q = { param($s) "'" + ($s -replace "'", "''") + "'" }
$claudeCmd = "$(Get-LaunchCommand $FleetCfg (Get-FleetAccount $FleetCfg $account) 'claude') $(& $q $prompt)"
# wt sets the working directory itself with -d, so it needs no Set-Location and stays
# semicolon-free. The other launchers have no such flag and must cd first.
$innerCd = "Set-Location $(& $q $Folder); $claudeCmd"

# Not $launch: PowerShell variable names are case-insensitive, so $launch would clobber
# the -Launch switch parameter.
$term = switch ($Terminal) {
    # wt splits its own arguments on ';', so escape any the launch command carries.
    'wt'     { @{ exe = 'wt.exe'; args = @('-w', '0', 'nt', '-d', $Folder, 'pwsh', '-NoExit', '-Command', ($claudeCmd -replace ';', '\;')); what = 'Windows Terminal tab' } }
    'tabby'  { @{ exe = $tabby;  args = @('run', 'pwsh', '-NoExit', '-Command', $innerCd); what = 'Tabby tab' } }
    'window' { @{ exe = 'pwsh';  args = @('-NoExit', '-Command', $innerCd); what = 'new console window' } }
}

Write-Host ''
Write-Host "  hand-off : $path"
Write-Host "  folder   : $Folder"
Write-Host "  account  : $account ($why)"
Write-Host ''

if ($DryRun) {
    Write-Host '  dry run: nothing written, nothing opened. The file would contain:'
    Write-Host ''
    Write-Host ($header + $body)
    Write-Host ''
    Write-Host '  and the command would be:'
    Write-Host ''
    Write-Host "    Set-Location '$Folder'"
    Write-Host "    $claudeCmd"
    Write-Host ''
    return
}

if (-not $Launch) {
    # Paste-ready, because this is what you would actually do by hand: open a tab in
    # your terminal yourself, then run this.
    Write-Host '  run this in a new tab:'
    Write-Host ''
    Write-Host "    Set-Location '$Folder'"
    Write-Host "    $claudeCmd"
    Write-Host ''
    Write-Host '  (add -Launch to open a terminal automatically)'
    Write-Host ''
    return
}

Write-Host "  opening  : $($term.what)"
Write-Host ''

if ($Terminal -eq 'window') { Start-Process -FilePath $term.exe -ArgumentList $term.args | Out-Null }
else { & $term.exe @($term.args) }

# Prove it rather than assume it: the tab is a separate process, so look for it.
Start-Sleep -Seconds 4
$found = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$([IO.Path]::GetFileName($path))*" }
if ($found) { Write-Host "  opened. new shell pid $($found.ProcessId -join ', ')" }
else { Write-Host '  WARNING: no new shell found. The hand-off file is written; launch it yourself.' }
Write-Host ''
