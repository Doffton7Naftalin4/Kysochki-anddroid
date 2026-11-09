# Build and review instructions

## Bundled compiler

The only bundled executable is the LuaJIT 2.0.3 compiler, not a game executable or a precompiled mod. Its upstream source is https://github.com/LuaJIT/LuaJIT at commit **880ca300e8fb7b432b9d25ed377db2102e4cb63d** (RELEASE LuaJIT-2.0.3).

Bundled `toolchain/LuaJIT-v2.0.3/src/luajit.exe` SHA-256:

```text
5744f45c1db66b9e76648a4e73fcba35d71bfffb3d9b9b2e666423132f7fe46e
```

It was built as a static Windows x86 executable with MSVC 2019 Build Tools 14.29.30133. From an **x86 Native Tools command prompt**, with Git available:

```bat
git clone https://github.com/LuaJIT/LuaJIT.git LuaJIT-source
cd LuaJIT-source
git checkout 880ca300e8fb7b432b9d25ed377db2102e4cb63d
cd src
msvcbuild.bat static
luajit.exe -v
```

Copy the resulting luajit.exe into this repository's `toolchain/LuaJIT-v2.0.3/src/` directory. Retain the upstream COPYRIGHT. A rebuild may differ byte-for-byte because of compiler/toolchain metadata. LuaJIT 2.0 bytecode version 1 is required; substituting a newer bytecode format is unsupported.

## Build/install the mod

Use a clean, supported Steam installation of HELLDIVERS. The scripts require original pinned archive hashes; game data is read locally and never downloaded from this project.

From the repository root in PowerShell:

```powershell
py -3 hd_camera.py install "C:\Program Files (x86)\Steam\steamapps\common\Helldivers"
```

This is the same Python entry point called by Instalar.cmd, but assumes Python 3.10+ is already installed. It compiles the Lua sources with `toolchain/compile-bytecode.lua`, wraps the user's original BOOT, generates native graph overlays, validates hashes and installs with local backups. Generated files live in build/, state/ and logs/ and must not be committed or shared.

To restore, with the game closed and from the same repository folder:

```powershell
py -3 hd_camera.py restore "C:\Program Files (x86)\Steam\steamapps\common\Helldivers"
```

Use your actual game path. Restore before changing sources and build a fresh copy; editing source files does not modify the installed compiled BOOT. Cached candidates are checked against their source hashes.

The automatic launcher reuses compatible Python or downloads official Python from python.org, verifies SHA-256 and publisher signature, and installs for the current user. See python_bootstrap.ps1 for the pinned URLs, hashes and flags.

## Tests without modifying the game

From the repository root:

```powershell
py -3 -B -m unittest test_build_mod package.test_patcher package.test_overlay
$runtime = '.\toolchain\LuaJIT-v2.0.3\src\luajit.exe'
foreach ($suite in @('test_aim.lua','test_native_pose.lua','test_actions.lua','test_throw_integration.lua','test_sky.lua')) {
    & $runtime $suite
    if ($LASTEXITCODE -ne 0) { throw "Failed: $suite" }
}
```

These use synthetic fixtures and temporary directories. They do not establish GPU output, online compatibility or game-runtime correctness. The source export preserves the runtime files from the tested 0.12.2 distribution.

Native-game integration suites are intentionally excluded because they require locally extracted copyrighted game bytecode. The five published Lua suites and Python tests run without that data.
