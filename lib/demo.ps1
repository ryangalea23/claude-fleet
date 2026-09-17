# The -Demo timeline, shared by ai-usage, fleet and dash.
#
# A fixture entry can carry "steps": [{ "at": 3, "state": "working", "done": 6 }, ...].
# At tick N, every step with "at" <= N is applied in order on top of the entry. -Watch
# advances the tick once per refresh, so a demo tells the same short story every run and
# then holds still on the last frame.

$script:DemoLastTick = 10

function Resolve-DemoEntry($entry, [int]$tick) {
    $tick = [Math]::Max(0, [Math]::Min($tick, $script:DemoLastTick))
    $o = [ordered]@{}
    foreach ($p in $entry.PSObject.Properties) { if ($p.Name -ne 'steps') { $o[$p.Name] = $p.Value } }
    # The tick at which the current state began, so idle time can count up from there.
    $o['stateSince'] = 0
    foreach ($s in @(@($entry.steps) | Where-Object { $_ -and $_.at -le $tick } | Sort-Object at)) {
        foreach ($p in $s.PSObject.Properties) { if ($p.Name -ne 'at') { $o[$p.Name] = $p.Value } }
        if ($s.PSObject.Properties['state']) { $o['stateSince'] = [int]$s.at }
    }
    $o['tick'] = $tick
    return [pscustomobject]$o
}
