# linuxmaker

A single-file GUI package builder for Linux. Point it at a source folder (or a
prebuilt binary) and it produces installable packages in **.deb**, **.rpm**, and
**.AppImage** formats — automatically compiling Go, Rust, C, and C++ sources
along the way.

Written in pure Bash + `zenity`. No dependencies beyond a handful of standard
Linux packaging tools, and no `npm`/`pip`/`cargo` machinery to install.

![linuxmaker](linuxmaker.png)

---

## Features

- **Three output formats in one tool**: `.deb`, `.rpm`, `.AppImage`
- **Four-step graphical wizard** (folder → settings → formats → destination)
- **Automatic source compilation**: detects `go.mod` (Go), `Cargo.toml` (Rust),
  `CMakeLists.txt` / `Makefile` / `.c` / `.cpp` sources (C/C++)
- **Auto-detect the entry executable** inside your source folder
- **Custom icon or built-in default** (64×64 PNG, bundled)
- **Automatic dependency installation**: asks to install `rpm` and build tools
  on demand when running in GUI mode
- **CLI mode** for scripting and CI
- **No compilation tools required** if you choose *"Already built (no compile)"*

---

## Requirements

Your distro's base packages:

| What | Needed for | Install |
|------|------------|---------|
| `bash` | runs the script | almost always present |
| `zenity` | GUI dialogs | `sudo apt install zenity` |
| `dpkg-deb` / `dpkg-dev` | `.deb` building | `sudo apt install dpkg-dev` |
| `tar` | archive helpers | usually present |
| `rpmbuild` | `.rpm` building | `sudo apt install rpm` |
| `squashfs-tools` (`mksquashfs`) | AppImage (fallback) | `sudo apt install squashfs-tools` |

**Optional** — only needed if you want automatic compilation:

| Tool | For |
|------|-----|
| `gcc` / `g++` | C / C++ |
| `go` | Go |
| `rustc` / `cargo` | Rust |
| `cmake` / `make` | CMake / Makefile projects |

### Quick install (Ubuntu / Debian)

```bash
sudo apt update
sudo apt install -y bash zenity dpkg-dev build-essential rpm squashfs-tools curl
```

---

## Usage

### 1. Make it executable

```bash
chmod +x linuxmaker.sh
```

### 2. Run the GUI wizard

```bash
./linuxmaker.sh
```

The wizard walks you through four steps:

1. **Select the app folder** to package
2. **Package settings** — name, version, entry executable, description,
   maintainer, architecture, project type, icon, output folder
3. **Output formats** — pick one or more of `.deb`, `.rpm`, `.AppImage`
4. **Destination folder** — where the finished packages are saved

A progress bar shows build activity in real time. On completion you get a
summary dialog listing the produced files.

---

## CLI mode

```bash
./linuxmaker.sh --cli NAME VERSION ENTRY SOURCE DEST FORMATS [ICON] [ARCH] [DESC] [MAINTAINER] [PROJECT_TYPE]
```

| Argument | Meaning | Default |
|----------|---------|---------|
| `NAME` | Package name | — (required) |
| `VERSION` | Package version | `1.0.0` |
| `ENTRY` | Entry executable name | auto-detect |
| `SOURCE` | Source folder | — (required) |
| `DEST` | Output folder | `~/Desktop/linuxmaker/output` |
| `FORMATS` | Comma-separated: `deb,rpm,appimage` | — (required) |
| `ICON` | Icon file path (optional) | bundled default |
| `ARCH` | Architecture | `amd64` |
| `DESC` | Description | `A packaged application` |
| `MAINTAINER` | Maintainer string | `$USER <$USER@localhost>` |
| `PROJECT_TYPE` | `auto\|go\|rust\|c\|cpp\|binary` | `auto` |

Example — build a `.deb` from a Go app:

```bash
./linuxmaker.sh --cli myapp 1.2.3 myapp ./myapp-src ~/Desktop/out deb
```

Example — build a `.deb` + `.AppImage` from a prebuilt binary:

```bash
./linuxmaker.sh --cli myapp 1.2.3 ./myapp ./myapp-src ~/Desktop/out "deb,appimage" --icon ./myapp.png amd64 "My app description" "Jane Doe <jane@example.com>" binary
```

---

## Project types

The *"Project type"* selector controls how the source folder is turned into an
executable. **Auto detect** looks for:

```
go.mod        →  Go
Cargo.toml    →  Rust
CMakeLists.txt → C/C++ (CMake)
Makefile      →  C/C++ (Make)
*.c / *.cpp   →  C / C++ (direct gcc/g++)
```

Any source-code type triggers compilation into a build directory before
packaging. Choose **Already built (no compile)** when you only want to wrap an
existing binary — no compilers or toolchains are required then.

---

## How it works

1. **Validate the source folder** and required tools.
2. **Compile** (unless `binary`): detect the project type, compile with the
   matching toolchain, and install the produced binary into a temporary
   `WORK` directory.
3. **Populate a rootfs**: if the source already looks like a rootfs (contains
   `usr/`), copy it as-is; otherwise install to
   `usr/lib/<name>` and symlink `usr/bin/<name>` → the entry.
4. **Write a `.desktop` file** in `usr/share/applications/` and install the
   icon into `usr/share/icons/hicolor/256x256/apps/`.
5. **Build each format**:

   - **`.deb`** — assembles `DEBIAN/control` + rootfs and runs `dpkg-deb --build`.
   - **`.rpm`** — prepares an `rpmbuild` tree (`BUILD`/`BUILDROOT`/`RPMS`/`SOURCES`/`SPECS`),
     creates a spec file, and runs `rpmbuild -bb`.
   - **`.AppImage`** — builds an AppDir (with an `AppRun` launcher), then either
     calls `appimagetool` directly or, if no `appimagetool` is installed,
     assembles the image manually with `mksquashfs` + a downloaded runtime
     (~700 KB, fetched from GitHub on demand).

6. Copies each produced package into the chosen output folder.
---

## File layout

```
linuxmaker/
├── linuxmaker.sh   # the whole tool (Bash + zenity)
├── linuxmaker.png  # app icon (64×64, used as default icon)
└── README.md       # this file
```

---

## Troubleshooting

### `zenity: command not found`

Install the GTK dialog package (Ubuntu/Debian): `sudo apt install zenity`

### `dpkg-deb: not found`

Install the Debian packager: `sudo apt install dpkg-dev`

### *"could not find an executable entry file"*

The source folder doesn't contain an executable file. Either:
- run the GUI, auto-detect the entry by selecting the right folder, or
- pass the entry explicitly with the `--cli` `ENTRY` argument.

### `rpmbuild not found`

The GUI will offer to install it automatically (`sudo apt install rpm`). You can
also install it manually.

### AppImage: *"no tooling available"*

Make sure at least one of the following is installed:
- `appimagetool` (download from GitHub), or
- `mksquashfs` (`squashfs-tools`) plus the AppImage runtime (~700 KB,
  downloaded automatically when the GUI is used).

### Permission denied after install (common with `.deb`)

The `Exec` line in the generated `.desktop` file is `Exec=<name>`, which relies
on the binary being in `PATH` and on a wrapper in `usr/bin`. If your binary
lives outside a standard prefix, either install it to a directory on `PATH`
(e.g. `/usr/local/bin`) or adjust the `.desktop` file after packaging.

---

## License

MIT — see the header comment in `linuxmaker.sh`. The bundled default icon is
from the public domain.

---

## Support

Open an issue on GitHub with:
- your distribution and `cat /etc/os-release`,
- the command you ran,
- the full build log (`~/.local/share/linuxmaker` and `/tmp/linuxmaker-*.log`).

