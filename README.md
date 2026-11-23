# Progress Log

A practice diary for CS:S bhop, as a SourceMod plugin. For each map it keeps your attempts as
"from → to" entries (run times, Start, End, or spots you named), grouped by day.

## Commands

| Command | What it does |
|---|---|
| `!prog` | opens the Progress Log window, or the chat menu if you don't have the window |
| `!prog 2:24 to 4:02` | logs an entry right away. Digits work like a timer: `224 to 402` is 2:24 to 4:02, and `95s` means seconds |
| `!progsave` | logs the attempt you just played: from where it began (Start, or your time at the checkpoint you loaded) to where you failed (your last teleport or death in the last 20 s, otherwise where you are now). Press it again before your next attempt to update it. Good to bind. |
| `!progmenu` | the chat menu |

**Spots** are names for a time range, e.g. `End slope 3:40-3:55`. Entries that use a spot's name take the
middle of its range. `End` is a spot too: your estimated finish time, which percentages are shown against.

Finished runs are logged on their own as "… to End" (you can turn that off in the menu).

## The window

The in-game window (log, graph, stats, spots) is the Progress Log book in
[bhoptools](https://github.com/brybry333/bhoptools). Players without it get the chat menu instead.
They also see `Unknown command: prog_ui` once in their console when they join.

## Install

Requirements: SourceMod 1.12+, [shavit's bhop timer](https://github.com/shavitush/bhoptimer) (built against
3.5.1), clientprefs and SQLite (both ship with SourceMod).

1. Copy `addons/sourcemod/plugins/progresslog.smx` into your server's `addons/sourcemod/plugins/`.
2. Change map.

All data is stored in the server's SQLite database `addons/sourcemod/data/sqlite/progresslog.sq3`, by Steam ID
and map. Every server keeps its own history.

## Settings

- `sm_prog_daystart` (default `5`): the hour a new day starts, so a late session still counts for the day it
  began. It's in `cfg/sourcemod/progresslog.cfg`.
- Each player's own settings are clientprefs cookies: `prog_autofinish`, `prog_saveat`, `prog_bin`.

## Build

```
spcomp addons/sourcemod/scripting/progresslog.sp
```

You need shavit's includes (`shavit/core.inc`, `shavit/checkpoints.inc`) in your include folder.

## License

GPL-3.0
