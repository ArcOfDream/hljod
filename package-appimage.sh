#!/bin/bash
# package the linux release as a self-contained AppImage.
# MUST run inside the build container (needs the container's libs:
# libunwind.so.1 / libc++ / libc++abi that the host may lack).
# Usage: ./package-appimage.sh   (run after ./build.sh release)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BIN="build/linux/hljod"
OUT="build/linux/hljod-x86_64.AppImage"
APPTOOL=".cache/appimagetool-x86_64.AppImage"
APPDIR="build/AppDir"

if [ ! -x "$BIN" ]; then
    echo "build/linux/hljod missing - run ./build.sh release first"
    exit 1
fi

# fetch appimagetool once
if [ ! -x "$APPTOOL" ]; then
    mkdir -p "$(dirname "$APPTOOL")"
    echo "Downloading appimagetool..."
    curl -L -o "$APPTOOL" \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPTOOL"
fi

# assemble AppDir
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$BIN" "$APPDIR/usr/bin/hljod"
# fonts resolve from the exe's dir (GetBasePath), exe lives in usr/bin
cp -r desktop/fonts "$APPDIR/usr/bin/fonts"

# bundle non-system libs (libc++, libc++abi, libunwind.so.1, SDL3).
# exclude ABI-stable core (loader, libc, libm, libgcc_s); everything else
# ships in the AppImage so host/container version drift can't break it.
for lib in $(ldd "$BIN" 2>/dev/null | awk '/=>/ {print $3}' | sort -u); do
    case "$lib" in
        */ld-linux*|*/libc.so*|*/libm.so*|*/libgcc_s.so*) continue ;;
    esac
    [ -f "$lib" ] && cp "$lib" "$APPDIR/usr/lib/"
done

# AppRun: point LD_LIBRARY_PATH at bundled libs
cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
SELF="$(readlink -f "$0")"
HERE="${SELF%/*}"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/bin/hljod" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# .desktop + icon
cat > "$APPDIR/usr/share/applications/hljod.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=hljod
Comment=SFX generator
Exec=hljod
Icon=hljod
Terminal=false
Categories=Audio;AudioVideo;
EOF
cp "$APPDIR/usr/share/applications/hljod.desktop" "$APPDIR/hljod.desktop"

cp "core/crow.png" "$APPDIR/hljod.png"

# build the AppImage
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$APPTOOL" "$APPDIR" "$OUT"

echo ""
echo "AppImage: $OUT"
echo "Test:     ./$OUT"
