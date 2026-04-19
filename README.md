# mpv Config Layout

This repository keeps the configuration and helper scripts for a portable `mpv` setup.

## Expected Layout

Place the files and folders in these locations relative to the repository root:

```text
.
|-- 7zr.exe                     # local helper binary, ignored by Git
|-- ffmpeg.exe                  # local helper binary, ignored by Git
|-- mpv.exe                     # local player binary, ignored by Git
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
    |-- mpv.conf
    |-- mpv-manager.json
    |-- mpv-manager.log         # generated locally, ignored by Git
    |-- fonts/
    |   `-- modernz-icons.ttf
    |-- script-opts/
    |   `-- modernz.conf
    `-- scripts/
        |-- modernz.lua
        `-- thumbfast.lua
```

## Notes

- Keep the `portable_config/` folder structure unchanged so `mpv` can find scripts, fonts, and script options correctly.
- `.exe` files are intentionally ignored. Keep local binaries such as `mpv.exe`, `ffmpeg.exe`, and `7zr.exe` at the repo root if you need them for your portable setup.
- `*.log` files are ignored because they are generated locally and should not be committed.
