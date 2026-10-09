# vhs demo/vs_fff.tape   (from the repo root; needs the daemon, fff-search in that python, and demo/vs_fff.py results)
Output demo/fsearch-vs-fff.mp4

Set Shell zsh
Set FontSize 24
Set Width 1600
Set Height 900
Set Padding 40
Set Margin 50
Set MarginFill "#2b2d42"
Set BorderRadius 14
Set WindowBar Colorful
Set Framerate 30
Set Theme { "name": "Ghostty Dark", "background": "#141414", "foreground": "#ebebf0", "cursor": "#ebebf0", "selection": "#333333", "black": "#1d1f21", "red": "#cc6666", "green": "#b5bd68", "yellow": "#f0c674", "blue": "#81a2be", "magenta": "#b294bb", "cyan": "#8abeb7", "white": "#c5c8c6", "brightBlack": "#666666", "brightRed": "#d54e53", "brightGreen": "#b9ca4a", "brightYellow": "#e7c547", "brightBlue": "#7aa6da", "brightMagenta": "#c397d8", "brightCyan": "#70c0b1", "brightWhite": "#eaeaea" }
Set TypingSpeed 140ms

Hide
Type "clear; /tmp/fffbench/venv/bin/python -I demo/vs_fff_demo.py ~/Developer/Lab/chromium demo/vs_fff_chromium.json Chromium" Enter
Sleep 20s
Show
Sleep 1s

Type "tab_strip_model.cc"
Sleep 2s
Ctrl+U
Type "ominbox_view"
Sleep 2.5s
Ctrl+U
Type "grep:kMaxTabCount" Enter
Sleep 3s
Ctrl+U
Type "grep:OnOmniboxFocus" Enter
Sleep 2.5s
Escape
Sleep 10s
