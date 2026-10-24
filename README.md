# Livewall

Live video wallpapers on Hyprland with automatic pause and manual controls.

## Features

- **Live wallpapers** via mpvpaper on the bottom layer, visible above stock Omarchy backgrounds
- **Video grid** with thumbnails (generated via ffmpeg, cached)
- **Mode switch**: Live ↔ Stock (fully stops mpvpaper in stock mode)
- **Manual pause/resume** and quick-pause via right-click on bar icon
- **Auto-pause** when a fullscreen window covers the workspace, on battery, or when locked
- **Folder selection** with support for nested directories (up to 3 levels)
- **Keybinding helper** with copy-to-clipboard for Hyprland config

## Dependencies

- `mpvpaper` — live wallpaper renderer
- `ffmpeg` — video thumbnail generation

Install: `sudo pacman -S mpvpaper ffmpeg`

## Installation

```bash
omarchy plugin add https://github.com/YOUR_USERNAME/livewall.git
omarchy plugin enable morph.livewall --section right
```

## Usage

Click the bar icon or press the keybinding to open the panel. Select a video, toggle Live mode, adjust auto-pause rules.

### Keybinding

The panel displays a ready-to-use `o.bind(...)` line. Copy it and paste into your `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + W", "Livewall", "omarchy-shell shell toggle morph.livewall")
```

The plugin **does not edit your Hyprland config** — you paste the line manually.

## Settings

Settings are stored in `~/.config/omarchy/shell.json` and survive restarts.

- `folder`: video folder (default `~/Videos`)
- `video`: currently selected video path
- `mode`: `"live"` or `"static"`
- `paused`: manual pause state
- `autoWindows`, `autoBattery`, `autoLock`: auto-pause toggles

## Limitations

- **Single monitor**: only one display (eDP-1); multi-monitor and hotplug untested
- **Widget coupling**: removing the widget from the bar disables the service (host semantics; re-add the widget to re-enable)
- **Stock wallpaper**: changing Omarchy's background while in Live mode works, but mpvpaper stays on top

## License

MIT
