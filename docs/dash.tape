# Records docs/dash.gif from made-up demo data. Run from the repo root: vhs docs/dash.tape
# (vhs 0.12.0 exits without writing the file; 0.11.0 works.)
Output docs/dash.gif

Set Shell "pwsh"
Set FontSize 14
Set Width 1480
Set Height 540
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Hide
Type "$PSStyle.OutputRendering = 'Ansi'; function prompt { '> ' }; Clear-Host"
Enter
Sleep 1s
Show

Type "./dash.ps1 -Demo -Watch"
Sleep 400ms
Enter
Sleep 6s
