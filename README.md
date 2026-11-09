# HELLDIVERS - Ground View

Experimental first-person and over-the-shoulder camera mod for the original **HELLDIVERS (2015)**. Source version **0.12.2**. Created by **David3scobar**, with development assisted by OpenAI Codex.

## Features

- Switch between classic top-down, shoulder and first-person cameras.
- Camera-relative movement and 3D firearm aiming, with experimental body/weapon alignment.
- Firing and reloading during dives and while prone; prone stratagem use.
- Map and mission-panel support; individual top-down fallback in vehicles/mechs.
- Optional starry background for close camera views.

The daytime shoulder sky was accepted in a local mission. Online separation/synchronization, all-map compatibility and measured performance remain unverified. Sideways/face-up prone pose variants are not included.

## Requirements and installation

Windows x64, original HELLDIVERS on Steam (tested build 6001293), and Python 3.10+. Python is detected or installed automatically from python.org if missing; that download requires internet. No pip dependencies or other mods are required.

1. Close HELLDIVERS completely.
2. Download this repository using **Code > Download ZIP**, or clone it; extract the complete folder outside Steam.
3. Run **Instalar.cmd**. It detects Steam, checks Python and builds the mod locally.
4. Wait for **Instalado y hash comprobado**, then start the game through Steam.
5. Enter a mission and press **F9**.

Keep the entire extracted folder and its **state** directory: they contain the local backups and receipts needed for restoration. For custom Steam paths, drag the game root folder onto Instalar.cmd. If Windows denies write access, run the installer as administrator.

## Controls

| Key | Action |
| --- | --- |
| F8 | Toggle camera/separation mod |
| F9 | Cycle top-down / shoulder / first-person; enables close views |
| F10 | Toggle experimental body alignment |
| F11 | Toggle starry background |
| Right mouse | Aim |
| Tab | Map |

The mod starts OFF. Vehicles/mechs use an individual top-down camera and restore the chosen close view when exiting.

## Updating and uninstalling

With the game closed, run **Restaurar.cmd from the previously installed folder** first. Wait for **Original restaurado y hash comprobado**. Install the new version from a fresh folder; keep each version with its own state. Restoring alone removes the mod, so F9 will not work until installation.

To uninstall, run Restaurar.cmd from the current installation folder. Python remains installed. Do not delete or mix state folders.

## Troubleshooting

- Runtime log: `logs/prototype.log` in the folder used to install the mod, if runtime logging started.
- Game crash reports: `%APPDATA%/Arrowhead/Helldivers/crash/CRASH_*.txt`.
- Installation errors are printed in the installer window. Capture the exact message and keep `state/receipt.json`.
- Modified or unsupported game files are rejected; do not bypass the checks.

## Source and build

See [BUILDING.md](BUILDING.md) for the complete compiler source reference, compiler build commands, local mod build steps and tests. Original game archives, extracted game code/assets, backups and generated patches are **not** distributed here. Patches are generated on each user's machine from their own installation.

## Credits and permissions

- Original game: Arrowhead Game Studios. This is an unofficial community mod.
- LuaJIT: Mike Pall; Lua: Lua.org, PUC-Rio. MIT notices are preserved in `toolchain/LuaJIT-v2.0.3/COPYRIGHT`.
- Archive-format reference: https://github.com/Zekfad/helldivers/tree/master/formats
- Thanks to prototype testers for reporting camera, aiming and animation issues.

Publication of these sources does not grant an open-source license for the original mod code. See the permissions on [Nexus Mods](https://www.nexusmods.com/helldivers/mods/13). Third-party components retain their original licenses.
