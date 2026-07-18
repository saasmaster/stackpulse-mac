# README images

Screenshots used by the top-level `README.md`. **All are captured from the real
app running in demo mode** (Settings → Sample data), so they show clearly-labelled
fabricated activity — never a real user's data. The "Sample data — not from your
Mac" banner is visible in the surfaces that render snapshot data.

| File | Surface |
| --- | --- |
| `popover.png` | Menu-bar popover — live limits + forecast, spend, active sessions |
| `sidebar.png` | Edge sidebar (Cards tab) — per-provider spend and limits |
| `home.png` | Main window, Home — spend, limits, and what needs you |
| `missions.png` | Missions — live agent sessions and their verification state |
| `diagnostics.png` | Diagnostics — health checks with repair steps |

## Regenerating

The app accepts maintainer launch args (like `--open-window`) for scripted capture:
`--section <name>` opens the main window on a section, `--show-popover` opens the
menu-bar popover, `--show-sidebar` shows the edge panel.

```bash
defaults write ai.stackpulse.mac demoMode -bool true
defaults write ai.stackpulse.mac "sidebar.tab" -string "cards"
"StackPulse.app/Contents/MacOS/StackPulseApp" --show-popover   # or --section home, --show-sidebar
# capture the window (⌘⇧4 then Space, or `screencapture -o -l<windowID>`)
defaults delete ai.stackpulse.mac demoMode   # back to real data
```

Note: history-based views (Usage → Trends / By Project) read the durable usage
store, which demo mode does not yet override — capture snapshot-based surfaces
(popover, sidebar Cards, Home, Missions, Overview, Diagnostics) so sample and real
data never mix.
