#!/usr/bin/env bash
#
# linuxmaker - GUI package builder for .deb, .rpm and .AppImage
#
# Usage:
#   ./linuxmaker.sh              (graphical mode with zenity)
#   ./linuxmaker.sh --cli NAME VERSION ENTRY SOURCE DEST FORMATS [ICON] [ARCH] [DESC] [MAINTAINER]
#
# FORMATS is a comma separated list: deb,rpm,appimage
#
set -u

PROG_VERSION="1.0"

# ---------- default icon (64x64 PNG, embedded) ----------
DEFAULT_ICON_B64="iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAn0lEQVR42u3bsQ2AMAwEwEzHYNSMSE3NBtDRIBARbhyfJQ/w16SIv7WPM83rkWnb38kWOAxktOBdEKOHf0WoEv4RoTRAtfA3BAAACgNUDX8hAAAAAAAAAADCd9+W0AUAAEAugOgBAAAAAK8AAAAAAAAAAAAAAAAAAAAAAAAAAAA+RwEAAAAAAAAA7oVdiwMAoDekNaY7qD2qQ6xN3hn4BMXfx68lgQE8AAAAAElFTkSuQmCC"

# ---------- config (overridable via --cli args or env) ----------
APP_NAME=""
APP_VERSION="1.0.0"
APP_ENTRY=""
APP_DESC="A packaged application"
APP_MAINTAINER=""
APP_ARCH="amd64"
APP_ICON=""
APP_SOURCE=""
APP_DEST=""
APP_FORMATS=""          # "deb rpm appimage"
WORK=""                 # temp build dir

info() { echo "[linuxmaker] $*"; }
die()  { echo "[linuxmaker] ERROR: $*" >&2; exit 1; }

rpm_arch() {
  case "$1" in
    amd64|x86_64) echo "x86_64" ;;
    arm64|aarch64) echo "aarch64" ;;
    i386|i686) echo "i686" ;;
    armhf) echo "armhfp" ;;
    *) echo "$1" ;;
  esac
}

appimage_arch() {
  case "$1" in
    amd64|x86_64) echo "x86_64" ;;
    arm64|aarch64) echo "aarch64" ;;
    i386|i686) echo "i686" ;;
    armhf) echo "armhf" ;;
    *) echo "$1" ;;
  esac
}

detect_entry() {
  # find the most likely runnable file in the source folder
  local f
  for f in "$APP_SOURCE"/"$APP_NAME"* "$APP_SOURCE"/*; do
    [ -f "$f" ] && [ -x "$f" ] && { basename "$f"; return 0; }
  done
  for f in "$APP_SOURCE"/*; do
    [ -f "$f" ] && [ -x "$f" ] && { basename "$f"; return 0; }
  done
  echo ""
}

check_dependencies() {
  command -v zenity >/dev/null 2>&1 || die "zenity not found. Install with: sudo apt install zenity"
  command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found. Install with: sudo apt install dpkg-dev"
  command -v tar  >/dev/null 2>&1 || die "tar not found."
}

# ---------- install missing tools ----------
ensure_rpmbuild() {
  command -v rpmbuild >/dev/null 2>&1 && return 0
  if [ "${GUI:-0}" = "1" ]; then
    if zenity --question --title="linuxmaker" \
        --text="rpmbuild is not installed.\n\nInstall it now? (sudo apt install rpm)" \
        --ok-label="Install" --cancel-label="Skip"; then
      zenity --info --title="linuxmaker" --text="Installing rpm... enter your password when asked." \
             --timeout=3 || true
      sudo apt-get install -y rpm || return 1
      command -v rpmbuild >/dev/null 2>&1
    else
      return 1
    fi
  else
    info "rpmbuild not found - install with: sudo apt install rpm"
    return 1
  fi
}

# AppImage tooling:
#   BUILD_METHOD="appimagetool"  -> use appimagetool binary
#   BUILD_METHOD="manual"        -> mksquashfs + runtime (no download of appimagetool needed)
RUNTIME_DIR="$HOME/.local/share/linuxmaker"
APPIMAGE_METHOD=""

ensure_appimage_tools() {
  if command -v appimagetool >/dev/null 2>&1 && appimagetool --version >/dev/null 2>&1; then
    APPIMAGE_METHOD="appimagetool"
    return 0
  fi
  if [ -x "$HOME/.local/bin/appimagetool" ] && "$HOME/.local/bin/appimagetool" --version >/dev/null 2>&1; then
    PATH="$HOME/.local/bin:$PATH"
    APPIMAGE_METHOD="appimagetool"
    return 0
  fi
  if command -v mksquashfs >/dev/null 2>&1; then
    if [ -x "$RUNTIME_DIR/runtime-$(uname -m)" ]; then
      APPIMAGE_METHOD="manual"
      return 0
    fi
    local text="mksquashfs found - AppImage can be built manually.\n\nA small runtime file (~700KB) is needed.\nDownload it now from GitHub (can take a couple of minutes)?"
    local ok=0
    if [ "${GUI:-0}" = "1" ]; then
      zenity --question --title="linuxmaker" \
          --text="$text" \
          --ok-label="Download" --cancel-label="Skip" && ok=1
    else
      ok=1
    fi
    if [ "$ok" = "1" ]; then
      download_runtime || return 1
      APPIMAGE_METHOD="manual"
      return 0
    fi
    return 1
  fi
  info "No AppImage tooling found (appimagetool or mksquashfs + runtime)."
  info "Install with: sudo apt install squashfs-tools"
  return 1
}

download_runtime() {
  local arch url dest
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  arch="x86_64" ;;
    aarch64) arch="aarch64" ;;
    armv7l)  arch="armhf" ;;
    *) die "Unsupported architecture for AppImage: $arch" ;;
  esac
  dest="$RUNTIME_DIR/runtime-$arch"
  url="https://github.com/AppImage/AppImageKit/releases/download/continuous/runtime-$arch"
  info "Downloading AppImage runtime ($arch)..."
  mkdir -p "$RUNTIME_DIR"
  curl -L --fail --silent --show-error --retry 5 -C - -o "$dest" "$url" || return 1
  chmod +x "$dest"
  info "Runtime installed to $dest"
  return 0
}

# ---------- source-code compilation (Go / Rust / C / C++) ----------
PROJECT_TYPE="auto"   # auto | go | rust | c | cpp | binary

ensure_tool() {
  local tool="$1" pkg="$2"
  command -v "$tool" >/dev/null 2>&1 && return 0
  if [ "${GUI:-0}" = "1" ]; then
    if zenity --question --title="linuxmaker" \
        --text="$tool is not installed.\n\nInstall it now? (sudo apt install $pkg)" \
        --ok-label="Install" --cancel-label="Skip"; then
      zenity --info --title="linuxmaker" --text="Installing $tool... enter your password when asked." \
             --timeout=3 || true
      sudo apt-get install -y "$pkg" || return 1
      command -v "$tool" >/dev/null 2>&1
    else
      return 1
    fi
  else
    info "$tool not found - install with: sudo apt install $pkg"
    return 1
  fi
}

detect_project_type() {
  local ext
  [ -f "$APP_SOURCE/go.mod" ] && { echo "go"; return; }
  [ -f "$APP_SOURCE/Cargo.toml" ] && { echo "rust"; return; }
  [ -f "$APP_SOURCE/CMakeLists.txt" ] && { echo "c"; return; }
  [ -f "$APP_SOURCE/Makefile" ] || [ -f "$APP_SOURCE/makefile" ] && { echo "c"; return; }
  compgen -G "$APP_SOURCE/*.c" >/dev/null && { echo "c"; return; }
  for ext in cpp cc cxx; do
    compgen -G "$APP_SOURCE/*.$ext" >/dev/null && { echo "cpp"; return; }
  done
  echo "binary"
}

find_binary() {
  local dir="$1" f
  [ -n "$dir" ] || return 1
  [ -x "$dir/$APP_NAME" ] && { echo "$dir/$APP_NAME"; return; }
  find "$dir" -maxdepth 3 -type f -executable \
    ! -name "*.so" ! -name "*.a" ! -name "*.d" ! -name "*.o" \
    ! -name "CMakeCache.txt" ! -name "cmake_install.cmake" \
    ! -name "Makefile" ! -path "*/CMakeFiles/*" 2>/dev/null | head -1
}

compile_project() {
  local type="$1" bin outdir="$WORK/build"
  case "$type" in
    go)
      ensure_tool go golang-go || return 1
      mkdir -p "$outdir"
      ( cd "$APP_SOURCE" && go build -trimpath -o "$outdir/$APP_NAME" . ) || return 1
      ;;
    rust)
      ensure_tool cargo rustc || return 1
      ( cd "$APP_SOURCE" && cargo build --release ) || return 1
      bin="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$APP_SOURCE/Cargo.toml" | head -1)"
      [ -n "$bin" ] || bin="$APP_NAME"
      [ -x "$APP_SOURCE/target/release/$bin" ] || \
        bin="$(find "$APP_SOURCE/target/release" -maxdepth 1 -type f -executable 2>/dev/null | head -1)"
      [ -n "$bin" ] || { info "Rust build produced no binary"; return 1; }
      mkdir -p "$outdir"
      cp "$bin" "$outdir/$APP_NAME" || return 1
      ;;
    c|cpp)
      local cxx=0
      [ "$type" = "cpp" ] && cxx=1
      if [ -f "$APP_SOURCE/CMakeLists.txt" ]; then
        ensure_tool cmake cmake || return 1
        ( cd "$APP_SOURCE" && cmake -S . -B "$WORK/cmakebuild" -DCMAKE_BUILD_TYPE=Release >/dev/null \
            && cmake --build "$WORK/cmakebuild" -j"$(nproc)" >/dev/null ) || return 1
        bin="$(find_binary "$WORK/cmakebuild")"
      elif [ -f "$APP_SOURCE/Makefile" ] || [ -f "$APP_SOURCE/makefile" ]; then
        ( cd "$APP_SOURCE" && make -j"$(nproc)" ) || return 1
        bin="$(find_binary "$APP_SOURCE")"
      else
        local srcs="" ext f
        if [ "$cxx" = "1" ]; then
          ensure_tool g++ g++ || return 1
          for ext in cpp cc cxx; do
            for f in "$APP_SOURCE"/*.$ext; do
              [ -f "$f" ] && srcs="$srcs $(basename "$f")"
            done
          done
          mkdir -p "$outdir"
          ( cd "$APP_SOURCE" && g++ -O2 -o "$outdir/$APP_NAME" $srcs ) || return 1
          return 0
        else
          ensure_tool gcc gcc || return 1
          for f in "$APP_SOURCE"/*.c; do
            [ -f "$f" ] && srcs="$srcs $(basename "$f")"
          done
          mkdir -p "$outdir"
          ( cd "$APP_SOURCE" && gcc -O2 -o "$outdir/$APP_NAME" $srcs -lm ) || return 1
          return 0
        fi
      fi
      [ -n "$bin" ] || { info "C/C++ build produced no binary"; return 1; }
      mkdir -p "$outdir"
      cp "$bin" "$outdir/$APP_NAME" || return 1
      ;;
    *)
      die "unknown project type: $type"
      ;;
  esac
  [ -x "$outdir/$APP_NAME" ] || { info "compile failed - no executable $APP_NAME produced"; return 1; }
  info "Compiled: $outdir/$APP_NAME"
  return 0
}

# ---------- package content helpers ----------
# If the source folder already looks like a rootfs (has usr/), copy it as-is.
# Otherwise install it to /usr/lib/<name> and create a wrapper in /usr/bin.
populate_rootfs() {
  local root="$1" entry
  if [ -d "$APP_SOURCE/usr" ]; then
    info "Source looks like a rootfs (contains usr/) - copying as-is"
    cp -a "$APP_SOURCE/." "$root/"
  else
    mkdir -p "$root/usr/lib/$APP_NAME" "$root/usr/bin"
    cp -a "$APP_SOURCE/." "$root/usr/lib/$APP_NAME/"
    if [ -n "$APP_ENTRY" ] && [ -f "$root/usr/lib/$APP_NAME/$APP_ENTRY" ]; then
      chmod +x "$root/usr/lib/$APP_NAME/$APP_ENTRY"
    fi
    ln -s "../lib/$APP_NAME/$APP_ENTRY" "$root/usr/bin/$APP_NAME"
  fi
}

write_desktop_file() {
  local root="$1"
  mkdir -p "$root/usr/share/applications"
  cat > "$root/usr/share/applications/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=$APP_DESC
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=false
Categories=Utility;
EOF
}

install_icon() {
  local root="$1"
  mkdir -p "$root/usr/share/icons/hicolor/256x256/apps"
  if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
    cp -a "$APP_ICON" "$root/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"
  else
    echo "$DEFAULT_ICON_B64" | base64 -d > "$root/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"
  fi
}

# ---------- format builders ----------
build_deb() {
  info "Building .deb package..."
  local pkg="$WORK/deb" out
  mkdir -p "$pkg/DEBIAN"
  populate_rootfs "$pkg"
  write_desktop_file "$pkg"
  install_icon "$pkg"
  local size
  size=$(du -sk "$pkg" | cut -f1)
  cat > "$pkg/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $APP_VERSION
Section: utils
Priority: optional
Architecture: $APP_ARCH
Maintainer: $APP_MAINTAINER
Installed-Size: $size
Description: $APP_DESC
EOF
  out="$APP_DEST/${APP_NAME}_${APP_VERSION}_${APP_ARCH}.deb"
  dpkg-deb --build --root-owner-group "$pkg" "$out" >/dev/null \
    || { info "dpkg build failed"; return 1; }
  info "Created: $out"
}

build_rpm() {
  info "Building .rpm package..."
  ensure_rpmbuild || { info "Skipping rpm (rpmbuild unavailable)"; return 1; }
  local top="$WORK/rpm" rarch
  rarch="$(rpm_arch "$APP_ARCH")"
  mkdir -p "$top/BUILD" "$top/BUILDROOT" "$top/RPMS" "$top/SOURCES" "$top/SPECS"
  populate_rootfs "$top/rootfs"
  write_desktop_file "$top/rootfs"
  install_icon "$top/rootfs"

  # file list for %files -f
  ( cd "$top/rootfs" && find usr \( -type f -o -type l \) | sed 's|^|/|' > "$top/SPECS/filelist" )

  tar -czf "$top/SOURCES/$APP_NAME-$APP_VERSION.tar.gz" -C "$top" rootfs

  cat > "$top/SPECS/$APP_NAME.spec" <<EOF
Name:           $APP_NAME
Version:        $APP_VERSION
Release:        1
Summary:        $APP_DESC
License:        MIT
BuildArch:      $rarch

%description
$APP_DESC

%prep
%setup -T -c

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xzf %{_sourcedir}/$APP_NAME-$APP_VERSION.tar.gz -C %{buildroot}

%files -f filelist

%changelog
EOF

  rpmbuild -bb --define "_topdir $top" --define "_sourcedir $top/SOURCES" \
           "$top/SPECS/$APP_NAME.spec" > "$WORK/rpm-build.log" 2>&1 \
    || { tail -20 "$WORK/rpm-build.log" >&2; info "rpm build FAILED - see $WORK/rpm-build.log"; return 1; }

  local rpmfile
  rpmfile=$(find "$top/RPMS" -name "*.rpm" | head -1)
  [ -n "$rpmfile" ] || { info "rpm build produced no output"; return 1; }
  cp "$rpmfile" "$APP_DEST/"
  info "Created: $APP_DEST/$(basename "$rpmfile")"
}

build_appimage() {
  info "Building AppImage..."
  ensure_appimage_tools || { info "Skipping AppImage (no tooling available)"; return 1; }
  local dir="$WORK/AppDir" aarch
  aarch="$(appimage_arch "$APP_ARCH")"
  rm -rf "$dir"
  mkdir -p "$dir/usr/share/applications"
  populate_rootfs "$dir"
  write_desktop_file "$dir"
  install_icon "$dir"

  # AppRun launcher
  cat > "$dir/AppRun" <<'EOF'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HERE/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/usr/bin/APP_NAME" "$@"
EOF
  sed -i "s/APP_NAME/$APP_NAME/g" "$dir/AppRun"
  chmod +x "$dir/AppRun"

  if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
    cp -a "$APP_ICON" "$dir/$APP_NAME.png"
  else
    echo "$DEFAULT_ICON_B64" | base64 -d > "$dir/$APP_NAME.png"
  fi

  local out="$APP_DEST/$APP_NAME-$APP_VERSION-$aarch.AppImage"
  if [ "$APPIMAGE_METHOD" = "manual" ]; then
    info "Using manual method (mksquashfs + runtime)"
    mksquashfs "$dir" "$WORK/app.squashfs" -root-owned -noappend >/dev/null 2>&1 \
      || { info "mksquashfs failed"; return 1; }
    cat "$RUNTIME_DIR/runtime-$(uname -m)" "$WORK/app.squashfs" > "$out" \
      || { info "failed to assemble AppImage"; return 1; }
    chmod +x "$out"
  else
    appimagetool "$dir" "$out" > "$WORK/appimage-build.log" 2>&1 \
      || { tail -20 "$WORK/appimage-build.log" >&2; info "AppImage build FAILED - see $WORK/appimage-build.log"; return 1; }
    chmod +x "$out"
  fi
  info "Created: $out"
}

# ---------- main build ----------
run_build() {
  [ -d "$APP_SOURCE" ] || die "source folder does not exist: $APP_SOURCE"
  [ -n "$APP_NAME" ] || die "no app name given"
  [ -n "$APP_MAINTAINER" ] || APP_MAINTAINER="$USER <$USER@localhost>"
  [ -n "$APP_ARCH" ] || APP_ARCH="amd64"
  [ -n "$APP_DESC" ] || APP_DESC="A packaged application"
  [ -n "$APP_DEST" ] || APP_DEST="$HOME/Desktop/linuxmaker/output"
  mkdir -p "$APP_DEST"

  WORK="$(mktemp -d /tmp/linuxmaker.XXXXXX)"
  local ptype="${PROJECT_TYPE:-auto}"
  [ "$ptype" = "auto" ] && ptype="$(detect_project_type)"
  info "Project type: $ptype"
  if [ "$ptype" != "binary" ] && [ "$(detect_project_type)" = "binary" ]; then
    info "No compilable sources found in the folder - treating it as a prebuilt app"
    ptype="binary"
  fi
  if [ "$ptype" != "binary" ]; then
    compile_project "$ptype" || die "compilation failed (see details above)"
    APP_SOURCE="$WORK/build"
    APP_ENTRY="$APP_NAME"
    info "Packaging compiled binary as: $APP_ENTRY"
  fi

  if [ -z "$APP_ENTRY" ]; then
    APP_ENTRY="$(detect_entry)"
    [ -n "$APP_ENTRY" ] && info "Detected entry executable: $APP_ENTRY"
  fi
  if [ -z "$APP_ENTRY" ] && [ ! -d "$APP_SOURCE/usr" ]; then
    die "could not find an executable entry file in $APP_SOURCE. Pass ENTRY explicitly."
  fi

  local ok=0 formats
  formats="${APP_FORMATS//,/ }"
  for f in $formats; do
    case "$f" in
      deb)      build_deb      && ok=1 ;;
      rpm)      build_rpm      && ok=1 ;;
      appimage) build_appimage && ok=1 ;;
      *) info "unknown format: $f" ;;
    esac
  done
  rm -rf "$WORK"
  [ "$ok" = "1" ] || die "no package was produced"
}

# ---------- GUI ----------
gui_main() {
  command -v zenity >/dev/null 2>&1 || die "zenity not found. Install with: sudo apt install zenity"

  # step 1: source folder (retry once on cancel/error)
  local try
  APP_SOURCE=""
  for try in 1 2; do
    APP_SOURCE=$(zenity --file-selection --directory \
      --title="linuxmaker - Step 1/4: Select the app folder to package")
    [ -n "$APP_SOURCE" ] && break
  done
  [ -n "$APP_SOURCE" ] || exit 0

  # step 2: one single form with all settings
  local form
  form=$(zenity --forms --title="linuxmaker - Step 2/4: Package settings" --width=520 \
    --text="App folder: $APP_SOURCE\n\nProject type: source code is compiled automatically\n(Auto detect: go.mod=Go, Cargo.toml=Rust, .c/.cpp/CMake/Make=C/C++)\n\nIcon path: leave empty to use the default icon.\nOutput folder: leave empty for ~/Desktop/linuxmaker/output\nEntry executable: leave empty to auto-detect" \
    --add-entry="Package name" \
    --add-entry="Version" \
    --add-entry="Entry executable" \
    --add-entry="Description" \
    --add-entry="Maintainer" \
    --add-combo="Architecture" \
    --combo-values="amd64|arm64|i386|armhf" \
    --add-combo="Project type" \
    --combo-values="Auto detect|Go|Rust|C|C++|Already built (no compile)" \
    --add-entry="Icon file path (optional)" \
    --add-entry="Output folder (optional)")
  local form_rc=$?
  if [ -z "$form" ]; then
    if [ "$form_rc" -ne 1 ]; then
      zenity --error --title="linuxmaker" --text="The settings dialog failed (code $form_rc)."
    fi
    exit 0
  fi
  IFS='|' read -r APP_NAME APP_VERSION APP_ENTRY APP_DESC APP_MAINTAINER APP_ARCH PROJECT_TYPE_RAW APP_ICON APP_DEST <<< "$form"
  APP_NAME=$(echo "$APP_NAME" | xargs)
  APP_VERSION=$(echo "$APP_VERSION" | xargs)
  [ -n "$APP_VERSION" ] || APP_VERSION="1.0.0"
  [ -n "$APP_DESC" ] || APP_DESC="A packaged application"
  [ -n "$APP_MAINTAINER" ] || APP_MAINTAINER="$USER <$USER@localhost>"
  [ -n "$APP_ARCH" ] || APP_ARCH="amd64"
  [ -n "$APP_ICON" ] && { [ -f "$APP_ICON" ] || APP_ICON=""; }
  [ -n "$APP_DEST" ] || APP_DEST="$HOME/Desktop/linuxmaker/output"
  [ -n "$APP_NAME" ] || APP_NAME="$(basename "$APP_SOURCE")"
  APP_ENTRY=$(echo "$APP_ENTRY" | xargs)
  APP_ICON=$(echo "$APP_ICON" | xargs)
  APP_DEST=$(echo "$APP_DEST" | xargs)
  case "${PROJECT_TYPE_RAW}" in
    "Go") PROJECT_TYPE="go" ;;
    "Rust") PROJECT_TYPE="rust" ;;
    "C++") PROJECT_TYPE="cpp" ;;
    "Already built (no compile)") PROJECT_TYPE="binary" ;;
    "C") PROJECT_TYPE="c" ;;
    *) PROJECT_TYPE="auto" ;;
  esac

  # step 3: formats
  APP_FORMATS=$(zenity --list --checklist --title="linuxmaker - Step 3/4: Output formats" --height=300 \
    --column="Pick" --column="Format" --column="Tool" \
    TRUE deb "dpkg-deb" \
    TRUE rpm "rpmbuild (installed automatically if missing)" \
    TRUE appimage "appimagetool or mksquashfs (runtime downloaded if missing)" \
    --separator=" ")
  local fmt_rc=$?
  if [ -z "$APP_FORMATS" ]; then
    if [ "$fmt_rc" -ne 1 ]; then
      zenity --error --title="linuxmaker" --text="The format dialog failed (code $fmt_rc)."
    fi
    exit 0
  fi

  # step 4: destination folder
  mkdir -p "$APP_DEST"
  local dest_picked
  dest_picked=$(zenity --file-selection --directory \
    --title="linuxmaker - Step 4/4: Where to save the packages" \
    --filename="$APP_DEST/")
  [ -n "$dest_picked" ] && APP_DEST="$dest_picked"

  local logfile
  logfile=$(mktemp /tmp/linuxmaker-gui.XXXXXX.log)
  {
    GUI=1
    run_build
    echo "EXIT:$?"
  } | tee "$logfile" | zenity --progress --pulsate --no-cancel \
      --title="linuxmaker" --text="Building packages..." --auto-close --auto-kill

  local produced
  produced=$(ls -1 "$APP_DEST" | grep -E "\.(deb|rpm|AppImage)$" || true)
  if [ -n "$produced" ]; then
    zenity --info --title="linuxmaker - Done" --width=480 \
      --text="Packages created in:\n$APP_DEST\n\n$produced"
  else
    zenity --error --title="linuxmaker" --width=480 \
      --text="Build failed or nothing was produced.\n\nDetails:\n$(tail -30 "$logfile")"
  fi
  rm -f "$logfile"
}

# ---------- entry point ----------
if [ "${1:-}" = "--cli" ]; then
  # --cli NAME VERSION ENTRY SOURCE DEST FORMATS [ICON] [ARCH] [DESC] [MAINTAINER] [PROJECT_TYPE]
  [ "$#" -ge 7 ] || die "usage: $0 --cli NAME VERSION ENTRY SOURCE DEST FORMATS [ICON] [ARCH] [DESC] [MAINTAINER] [PROJECT_TYPE]"
  APP_NAME="$2"; APP_VERSION="$3"; APP_ENTRY="$4"; APP_SOURCE="$5"; APP_DEST="$6"; APP_FORMATS="$7"
  [ "$#" -ge 8 ] && APP_ICON="$8"
  [ "$#" -ge 9 ] && APP_ARCH="$9"
  [ "$#" -ge 10 ] && APP_DESC="${10}"
  [ "$#" -ge 11 ] && APP_MAINTAINER="${11}"
  [ "$#" -ge 12 ] && PROJECT_TYPE="${12}"
  check_dependencies
  run_build
else
  check_dependencies
  gui_main
fi
exit 0
