# Records docs/ai-usage.gif from made-up demo data. Run from the repo root: vhs docs/ai-usage.tape
# (vhs 0.12.0 exits without writing the file; 0.11.0 works.)
Output docs/ai-usage.gif

Set Shell "pwsh"
Set FontSize 14
Set Width 1480
Set Height 620
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

# Startup is hidden so the first frame already shows the rendered cards.
# -Demo -Watch plays a scripted story: usage drains, a session window empties, a token expires.
Hide
Type "$PSStyle.OutputRendering = 'Ansi'; function prompt { '> ' }; Clear-Host"
Enter
Sleep 1s
Type "./ai-usage.ps1 -Demo -Watch"
Enter
Sleep 1500ms
Show

# The demo story takes about ten refreshes, one a second, then holds still.
Sleep 15s
