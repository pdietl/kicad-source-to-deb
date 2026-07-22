#!/usr/bin/env bash
set -euo pipefail

# Remove a prior KiCad installed from source under /usr/local.
#
# /usr/local/bin precedes /usr/bin on the default PATH, so an old source install
# shadows the packaged one: apt reports success and the stale binary keeps
# running. This is deliberately NOT done from a maintainer script -- Debian
# Policy reserves /usr/local for the local administrator.

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/uninstall.sh
. "$SCRIPT_DIR/lib/uninstall.sh"

PREFIX=/usr/local
MANIFEST=${1:-}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

if [ -n "$MANIFEST" ]; then
    if [ ! -r "$MANIFEST" ]; then
        echo "Error: manifest '$MANIFEST' does not exist or is not readable" >&2
        exit 1
    fi

    echo "Removing files listed in $MANIFEST"
    if ! kicad_uninstall_process_manifest "$MANIFEST" "$PREFIX"; then
        echo "Error: manifest contained one or more paths outside $PREFIX" >&2
        exit 1
    fi
else
    echo "No install manifest given; removing known /usr/local KiCad paths"

    rm -rf "$PREFIX/share/kicad"

    # KiCad's shared libraries land under the Debian multiarch subdir
    # ($PREFIX/lib/x86_64-linux-gnu/), but a bare -DCMAKE_INSTALL_PREFIX
    # build can also put them straight in $PREFIX/lib -- cover both, and the
    # kiface plugin/3D-plugin tree each one may carry alongside them.
    for libdir in "$PREFIX/lib" "$PREFIX/lib/x86_64-linux-gnu"; do
        [ -d "$libdir" ] || continue
        rm -f "$libdir"/libkicommon.so* "$libdir"/libkiapi.so* \
            "$libdir"/libkicad_3dsg.so* "$libdir"/libkigal.so*
        rm -rf "$libdir/kicad"
    done

    rm -f "$PREFIX"/bin/kicad "$PREFIX"/bin/kicad-cli "$PREFIX"/bin/eeschema \
        "$PREFIX"/bin/pcbnew "$PREFIX"/bin/gerbview "$PREFIX"/bin/pl_editor \
        "$PREFIX"/bin/pcb_calculator "$PREFIX"/bin/bitmap2component \
        "$PREFIX"/bin/dxf2idf "$PREFIX"/bin/idf2vrml "$PREFIX"/bin/idfcyl \
        "$PREFIX"/bin/idfrect \
        "$PREFIX"/bin/_cvpcb.kiface "$PREFIX"/bin/_eeschema.kiface \
        "$PREFIX"/bin/_gerbview.kiface "$PREFIX"/bin/_kipython.kiface \
        "$PREFIX"/bin/_pcb_calculator.kiface "$PREFIX"/bin/_pcbnew.kiface \
        "$PREFIX"/bin/_pl_editor.kiface

    rm -f "$PREFIX"/lib/python3/dist-packages/pcbnew.py \
        "$PREFIX"/lib/python3/dist-packages/_pcbnew.so

    kicad_uninstall_remove_desktop_integration "$PREFIX"
fi

# Prune directories now left empty by the removals above. Restricted to
# subtrees KiCad owns exclusively and to already-empty results (-empty), so
# a directory still holding unrelated local files is never touched.
# $PREFIX/bin and $PREFIX/lib themselves are shared with other software and
# are never removed here, only the files placed directly in them above.
for d in "$PREFIX/share/kicad" "$PREFIX/lib/kicad" "$PREFIX/lib/x86_64-linux-gnu/kicad"; do
    [ -d "$d" ] || continue
    find "$d" -depth -type d -empty -delete
done

ldconfig

# The .deb's own desktop/MIME/icon caches are refreshed via dpkg triggers,
# but those triggers only fire for /usr/share; a manual /usr/local cleanup
# gets no trigger, so the caches are refreshed here explicitly. Each tool is
# optional on the host and its failure does not abort the script.
if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$PREFIX/share/applications" ]; then
    update-desktop-database "$PREFIX/share/applications" || true
fi
if command -v update-mime-database >/dev/null 2>&1 && [ -d "$PREFIX/share/mime" ]; then
    update-mime-database "$PREFIX/share/mime" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -d "$PREFIX/share/icons/hicolor" ]; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" || true
fi

echo "Done. /usr/local KiCad removed."
