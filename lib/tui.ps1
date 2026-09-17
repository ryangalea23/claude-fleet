# Shared terminal rendering for the dashboards (ai-usage, fleet, dash, vitals, snapshot).
#
# One implementation on purpose: these two scripts should look like one tool, and two
# copies of a bar renderer drift within a week. Dot-source this, then call Init-Tui once.
#
#   . "$PSScriptRoot\lib\tui.ps1"
#   Init-Tui -Ascii:$Ascii
#   Write-Grid (Build-Card $lines) ...

function Init-Tui {
    param([switch]$Ascii)

    # Box and bar glyphs need a UTF-8 console. Falling back to ASCII is better than
    # printing mojibake, which is what a non-UTF-8 code page produces.
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { $Ascii = $true }

    $script:TuiAscii = [bool]$Ascii
    $script:ESC = [char]27

    # Truecolor. The basic 8 render as harsh primaries on a dark terminal; these are the
    # muted tones that make a dense dashboard readable instead of shouty.
    function script:RGB($r, $g, $b) { "$script:ESC[38;2;$r;$g;${b}m" }
    $script:C = @{
        reset  = "$script:ESC[0m"; bold = "$script:ESC[1m"
        green  = RGB 126 192 132
        yellow = RGB 221 170 92
        red    = RGB 224 108 100
        blue   = RGB 122 174 214
        grey   = RGB 92 99 112
        white  = RGB 228 232 240
    }
    if ($script:TuiAscii) { foreach ($k in @($script:C.Keys)) { $script:C[$k] = '' } }

    $script:G = if ($script:TuiAscii) {
        @{ tl = '+'; tr = '+'; bl = '+'; br = '+'; h = '-'; v = '|'
           fill = '='; empty = '-'; mark = '|'; dot = 'o'; ok = 'ok'; ellipsis = '.'; middot = '-' }
    } else {
        @{ tl = "$([char]0x250C)"; tr = "$([char]0x2510)"; bl = "$([char]0x2514)"; br = "$([char]0x2518)"
           h = "$([char]0x2500)"; v = "$([char]0x2502)"; fill = "$([char]0x2501)"; empty = "$([char]0x2500)"
           mark = "$([char]0x2503)"; dot = "$([char]0x25CF)"; ok = "$([char]0x2713)"
           ellipsis = "$([char]0x2026)"; middot = "$([char]0x00B7)" }
    }
}

function Get-TuiColors { $script:C }
function Get-TuiGlyphs { $script:G }

function Pct-Color($p) {
    if ($null -eq $p) { return $script:C.grey }
    if ($p -ge 50) { return $script:C.green }
    if ($p -ge 20) { return $script:C.yellow }
    return $script:C.red
}

# Length as the terminal sees it: colour codes take no columns.
function Vis-Len($s) { ($s -replace "$([regex]::Escape($script:ESC))\[[0-9;]*m", '').Length }

function Pad-To($s, $w) { $s + (' ' * [Math]::Max(0, $w - (Vis-Len $s))) }

# Text from transcripts, hooks, Codex and vendor APIs is untrusted. A title holding an
# escape sequence could clear the screen, retitle the terminal, or write the clipboard
# (OSC 52) the moment it is printed. Replace every control character with a space: C0
# (0x00-0x1F, which includes ESC and BEL), DEL, and C1 (0x80-0x9F). Everything else,
# accents and CJK included, is left alone. -KeepLines keeps newline and tab for
# multi-line text such as a Codex answer.
function Clean-Text($s, [switch]$KeepLines) {
    if ($null -eq $s) { return '' }
    $rx = if ($KeepLines) { '[\x00-\x08\x0B-\x1F\x7F-\x9F]' } else { '[\x00-\x1F\x7F-\x9F]' }
    return [regex]::Replace([string]$s, $rx, ' ')
}

# Callers pass plain text, never text that already carries this tool's own colour codes,
# so it is safe to clean here: colour is added around the result, not inside it.
function Fit($s, $w) {
    if ($null -eq $s) { return '' }
    $s = ((Clean-Text $s) -replace '\s+', ' ').Trim()
    if ($s.Length -le $w) { return $s }
    return $s.Substring(0, [Math]::Max(1, $w - 1)) + $script:G.ellipsis
}

# A bar of headroom or progress. $marker, when given, draws where the value "should" be,
# so the eye compares position instead of reading a second number.
function Render-Bar($pct, $marker, $width, $color) {
    if ($null -eq $pct) { return ($script:C.grey + ($script:G.empty * $width) + $script:C.reset) }
    $fill = [int][Math]::Round($width * ([double]$pct) / 100)
    $fill = [Math]::Max(0, [Math]::Min($width, $fill))
    $cells = @(for ($i = 0; $i -lt $width; $i++) {
        if ($i -lt $fill) { @{ ch = $script:G.fill; col = $color } }
        else { @{ ch = $script:G.empty; col = $script:C.grey } }
    })
    if ($null -ne $marker) {
        $mi = [int][Math]::Round($width * ([double]$marker) / 100)
        $mi = [Math]::Max(0, [Math]::Min($width - 1, $mi))
        $cells[$mi] = @{ ch = $script:G.mark; col = $script:C.white }
    }
    $out = ''; $cur = ''
    foreach ($c in $cells) {
        if ($c.col -ne $cur) { $out += $c.col; $cur = $c.col }
        $out += $c.ch
    }
    return $out + $script:C.reset
}

# A header line with something pinned left and something pinned right.
function Split-Line($left, $right, $inner) {
    $gap = [Math]::Max(1, $inner - (Vis-Len $left) - (Vis-Len $right))
    return $left + (' ' * $gap) + $right
}

function Build-Card($lines, $inner) {
    $g = $script:G; $c = $script:C
    $out = @("$($c.grey)$($g.tl)$($g.h * ($inner + 2))$($g.tr)$($c.reset)")
    foreach ($l in $lines) { $out += "$($c.grey)$($g.v)$($c.reset) " + (Pad-To $l $inner) + " $($c.grey)$($g.v)$($c.reset)" }
    $out += "$($c.grey)$($g.bl)$($g.h * ($inner + 2))$($g.br)$($c.reset)"
    return , $out
}

# Lay cards out two-up when the terminal is wide enough, one-up when it is not.
function Write-Grid($cards, $inner, $twoUp) {
    if (-not $twoUp) {
        foreach ($card in $cards) { $card; '' }
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

# Terminal geometry, in one place so both dashboards wrap identically.
# -Width overrides the real console width. [Console]::WindowWidth cannot be set from a
# script, so without this there is no way to test that the layout holds at 80 or 160
# columns, and alignment is the thing most likely to break.
function Get-Layout {
    param([int]$MaxInner = 52, [int]$Width = 0)
    $width = if ($Width -gt 0) { $Width } else { try { [Console]::WindowWidth } catch { 120 } }
    if ($width -lt 40) { $width = 120 }
    $twoUp = $width -ge 112
    $inner = if ($twoUp) { [Math]::Min($MaxInner, [int](($width - 8) / 2)) } else { [Math]::Min(64, $width - 6) }
    return @{ Width = $width; TwoUp = $twoUp; Inner = $inner }
}
