# README images

Screenshots used by the top-level `README.md`. All are captured from the real app
running in **demo mode** (Settings → Sample data, or the cold-start hero's "See it
with sample data"), so they show clearly-labelled fabricated activity — never a
real user's data.

| File | Section |
| --- | --- |
| `hero.png` | Home — today's spend, live limits, active sessions |
| `missions.png` | Missions — live agent sessions and their verification state |
| `diagnostics.png` | Diagnostics — health checks with repair steps |

## Regenerating

The app accepts `--section <name>` (a maintainer affordance, like `--open-window`)
to open the main window on a named section for scripted capture:

```bash
defaults write ai.stackpulse.mac demoMode -bool true
"StackPulse.app/Contents/MacOS/StackPulseApp" --section home --open-window
# then capture the window (e.g. ⌘⇧4 then Space, or `screencapture -o -l<id>`)
defaults delete ai.stackpulse.mac demoMode   # back to real data
```

Note: history-based views (Usage → Trends / By Project) read the durable usage
store, which demo mode does not yet override — capture snapshot-based sections
(Home, Missions, Overview, Diagnostics) to keep sample and real data from mixing.
