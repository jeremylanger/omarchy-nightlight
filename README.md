# Night Light

Omarchy bar widget for the built-in night light (hyprsunset): on/off switch and an editable schedule, next to the clock.

![Night Light panel](preview.png)

- Click the icon to open the panel; right-click to toggle without opening.
- Edit turn-on time, turn-off time, and temperature, then Apply. This writes `~/.config/hypr/hyprsunset.conf` and restarts hyprsunset.
- Changing only the temperature while the light is on applies instantly, with no flash. The hyprsunset restart it needs is deferred until the light is next off.
- The icon hides when the light is off and reveals on hover, like the stock indicators.

## Install

```bash
omarchy plugin add https://github.com/jeremylanger/omarchy-nightlight --enable
```

Optional: remove the stock night light indicator so this one takes its place. In `~/.config/omarchy/shell.json`, set `items` on the `omarchy.indicators` entry to exclude `NightLight`, then place this widget next to it:

```bash
omarchy bar move io.github.jeremylanger.nightlight --section center
```

For the schedule to run at login, make sure `~/.config/hypr/autostart.lua` has:

```lua
o.launch_on_start("hyprsunset")
```

## Remove

```bash
omarchy plugin remove io.github.jeremylanger.nightlight
```

Your `hyprsunset.conf` is left as is.

## IPC

```bash
omarchy-shell io.github.jeremylanger.nightlight open    # or close, toggle, apply
```

## Dependencies

Omarchy (Quattro or newer) and hyprsunset, both part of a stock install. No external services.

## License

MIT
