# mpv Portable Config Template

A shareable personal `mpv` setup built around the [mpv.rocks](https://mpv.rocks/) portable layout, ModernZ, and a few custom Lua scripts for subtitle, audio, and input behavior.

## What This Repo Is

This repository is the setup I actually use, cleaned up enough to share with other `mpv` users.

Right now, it is best treated as a template and reference project, not as a polished one-click installer. The intended flow is:

1. Set up `mpv` first with [mpv.rocks](https://mpv.rocks/).
2. Copy this repo's config files, or just the parts you want, into your own install.
3. Adjust the files to match your own preferences.

If you like customizing `mpv` by hand, this should be useful. If you want a beginner-friendly installer, that part is not built yet.

## Quick Start

1. Create a working portable `mpv` install using [mpv.rocks](https://mpv.rocks/).
2. Make sure the install has the usual portable structure, including `portable_config/`.
3. Close `mpv`.
4. Copy this repo's `portable_config/` contents into your own `portable_config/` folder.
5. Start `mpv` and test the setup.
6. Tweak the files listed in the customization section below.

On a typical Windows portable install, the target folder is:

```text
<your-mpv-folder>/portable_config/
```

If you already have your own scripts or config, merge carefully instead of blindly overwriting everything.

## Features

- ModernZ-based UI with custom behavior and styling
- Custom audio track picker menu
- Custom subtitle menu with `primary`, `dual`, and `off` modes
- Smart subtitle selection logic that tries to choose better subtitle tracks automatically
- PotPlayer-style keybinds for seeking, speed, and track switching
- Right-click menu behavior and double-right-click fullscreen toggle
- Speed toggle that jumps between `1.0x` and your last custom playback speed
- Tuned `mpv.conf` defaults for playback quality, screenshots, subtitle display, and anime-focused debanding profiles

## Expected Portable Layout

This tree is included on purpose because the repo does not track the player binaries. It shows where everything belongs in a normal portable setup:

```text
.
|-- 7zr.exe                     # local helper binary, not tracked
|-- ffmpeg.exe                  # local helper binary, not tracked
|-- mpv.exe                     # local player binary, not tracked
|-- mpv.com
|-- mpv-register.bat
|-- mpv-unregister.bat
|-- updater.bat
|-- doc/
|   |-- manual.pdf
|   `-- mpbindings.png
|-- installer/
|   `-- updater.ps1
|-- mpv/
|   `-- fonts.conf
|-- mpv-manager/
|   |-- create-shortcut.vbs
|   |-- mpv-register.bat
|   |-- mpv-unregister.bat
|   `-- uninstall.bat
`-- portable_config/
    |-- input.conf
    |-- mpv.conf
    |-- mpv-manager.json
    |-- fonts/
    |   `-- modernz-icons.ttf
    |-- script-opts/
    |   |-- audio_menu.conf
    |   |-- console.conf
    |   |-- context-menu.conf
    |   |-- modernz.conf
    |   |-- pause_indicator_lite.conf
    |   `-- subtitle_menu.conf
    `-- scripts/
        |-- audio_menu.lua
        |-- menu_ui.lua
        |-- modernz.lua
        |-- pause_indicator_lite.lua
        |-- persistent_prefs.lua
        |-- right_click.lua
        |-- speed_toggle.lua
        |-- subtitle_menu.lua
        `-- thumbfast.lua
```

## Project Layout

| Path | Purpose |
|------|---------|
| `portable_config/mpv.conf` | Main playback, rendering, screenshot, subtitle, and profile settings |
| `portable_config/input.conf` | Keyboard and mouse bindings |
| `portable_config/script-opts/modernz.conf` | ModernZ look, hover behavior, button actions, and layout |
| `portable_config/script-opts/audio_menu.conf` | Audio menu style and placement |
| `portable_config/script-opts/subtitle_menu.conf` | Subtitle menu style and placement |
| `portable_config/scripts/menu_ui.lua` | Shared menu renderer used by the custom audio/subtitle menus |
| `portable_config/scripts/audio_menu.lua` | Audio track menu |
| `portable_config/scripts/subtitle_menu.lua` | Subtitle menu with primary/secondary track selection |
| `portable_config/scripts/persistent_prefs.lua` | Persistent volume and smart subtitle mode logic |
| `portable_config/scripts/right_click.lua` | Single right-click menu and double-right-click fullscreen behavior |
| `portable_config/scripts/speed_toggle.lua` | Toggle between `1.0x` and the last saved custom speed |
| `portable_config/fonts/modernz-icons.ttf` | Icon font used by the UI |
| `portable_config/mpv-manager.json` | Local metadata used by the portable setup |

## Keybinds

These are the most important custom bindings:

| Key | Action |
|-----|--------|
| `a` | Open the audio menu |
| `l` | Open the subtitle menu |
| `Ctrl+l` | Cycle subtitle mode |
| `L` | Cycle subtitle track the normal `mpv` way |
| `z` | Toggle between `1.0x` and your last custom speed |
| `x` / `c` | Decrease / increase speed by `0.1` |
| `Left` / `Right` | Seek `-5s` / `+5s` |
| `Ctrl+Left` / `Ctrl+Right` | Seek `-30s` / `+30s` |
| `Alt+Left` / `Alt+Right` | Exact seek `-1s` / `+1s` |
| `PgDn` / `PgUp` | Previous / next chapter |
| `Right click` | Open the menu |
| `Double right click` | Toggle fullscreen |

## Customization

If you want to make this setup your own, start here:

- Edit `portable_config/mpv.conf` for playback quality, subtitle defaults, screenshot output, and general player behavior.
- Edit `portable_config/input.conf` for keyboard and mouse controls.
- Edit `portable_config/script-opts/modernz.conf` for UI layout, button behavior, colors, and hover effects.
- Edit `portable_config/script-opts/audio_menu.conf` and `portable_config/script-opts/subtitle_menu.conf` for the custom popup menu look and placement.
- Edit the Lua files in `portable_config/scripts/` if you want to change the actual logic.

The most opinionated parts of this setup are:

- ModernZ styling and button behavior
- The custom audio/subtitle popup menus
- The automatic subtitle selection rules
- The PotPlayer-inspired input layout

## Reusing Parts of This Setup

You do not need to adopt everything.

Common ways to reuse this repo:

- Copy only `mpv.conf` if you mainly want playback defaults.
- Copy `input.conf` if you mainly want the keybind layout.
- Copy `scripts/`, `script-opts/`, and `fonts/` if you want the menu system and UI behavior.
- Copy the full `portable_config/` folder into a fresh [mpv.rocks](https://mpv.rocks/) install if you want the closest match to my setup.

If you are not using the same portable layout, you can still reuse almost all of this manually. The important part is keeping the `portable_config/` structure intact so scripts, fonts, and script options resolve correctly.

## Current Limitations

- There is no guided installer yet.
- This is still a custom personal system, not a polished package for every kind of user.
- Some choices are very specific to how I use `mpv`, especially subtitle behavior and input bindings.
- If you already run a heavily customized `mpv` setup, you may need to reconcile script conflicts or duplicate keybindings.

## Ideas For Improving Distribution Later

If I turn this into an easier setup later, these are the obvious next steps:

- Split the repo into `base`, `ui`, and `optional` modules
- Add an install script that copies selected pieces into `portable_config/`
- Move personal defaults into a smaller override file
- Add screenshots or short demos of the menus and UI
- Document conflicts and compatibility notes for common `mpv` scripts

## Included and Not Included

This repository is mainly about the configuration layer.

- The tracked files focus on `portable_config/` and helper files around it.
- Generated logs are ignored.
- Local binaries such as `mpv.exe`, `ffmpeg.exe`, and `7zr.exe` are not meant to be the main shareable part of the repo.

The easiest way for other people to get the actual player binaries is still [mpv.rocks](https://mpv.rocks/).

## Credits

- [mpv](https://mpv.io/)
- [mpv.rocks](https://mpv.rocks/) for the initial portable setup
- [ModernZ](https://github.com/Samillion/ModernZ)
- Bundled helper scripts such as `thumbfast.lua` and `pause_indicator_lite.lua`

Third-party components keep their own upstream licensing and attribution where applicable.

## License

This repository is licensed under `GPL-3.0`. See [LICENSE](LICENSE).
