# Contributing

Issues and pull requests are welcome. Please keep Blinky small and native: no third-party dependencies,
no network access.

## Building

```bash
./build.sh              # build/Blinky.app for this Mac
./build.sh --install    # install to ~/Applications and launch
./build.sh --zip        # universal app + release zip
```

Only the Command Line Tools are required. Handy debug flags of the binary
(`build/Blinky.app/Contents/MacOS/Blinky`):

| Flag | What it does |
|---|---|
| `--dump` | print what the detectors see right now |
| `--render <dir>` | render break screens and settings tabs to PNG (add `-AppleLanguages '(ru)'` for another language) |
| `--settings` | open Settings on launch |
| `BLINKY_LOG=1` (env) | log scheduler state changes |

## Code map

| File | Responsibility |
|---|---|
| `Scheduler.swift` | the state machine, ticks once a second |
| `Detectors.swift` | microphone, camera, video, screen sharing, games, idle, Focus |
| `Posture.swift` | standing-desk posture and exercises |
| `Overlays.swift` | break window, heads-up, blink and posture reminders, toasts |
| `SettingsView.swift` | Settings window |
| `CalendarWatch.swift`, `Hotkeys.swift`, `Actions.swift` | calendar, global hotkeys, sounds / music / Shortcuts |
| `Prefs.swift`, `L10n.swift` | settings keys and defaults, statistics, localization helpers |

## Translations

Keys are the English texts themselves, so English needs no table.

1. Copy `Resources/ru.lproj` to `Resources/<code>.lproj` (e.g. `de.lproj`) and translate the right-hand sides
   of `Localizable.strings` and `InfoPlist.strings`. Keep the `%@`, `%d`, `%lld` placeholders.
2. Add the code to `CFBundleLocalizations` in `build.sh` and to `AppLanguage.options` in `Sources/Blinky/L10n.swift`.
3. Run `scripts/check-l10n.py <code>` — it lists UI strings missing from your table
   (paths and internal keys in its output can be ignored).
4. Check the result: `build/Blinky.app/Contents/MacOS/Blinky --render /tmp/shots -AppleLanguages '(<code>)'`.

When you add a UI string in code, add its Russian translation to `Resources/ru.lproj/Localizable.strings` too.
