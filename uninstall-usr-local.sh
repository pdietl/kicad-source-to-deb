#!/usr/bin/env bash
set -euo pipefail

# Remove a prior KiCad installed from source under /usr/local.
#
# /usr/local/bin precedes /usr/bin on the default PATH, so an old source install
# shadows the packaged one: apt reports success and the stale binary keeps
# running. This is deliberately NOT done from a maintainer script -- Debian
# Policy reserves /usr/local for the local administrator.

MANIFEST=${1:-}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    echo "Removing files listed in $MANIFEST"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            /usr/local/*) rm -f "$f" ;;
            *) echo "  skipping out-of-prefix path: $f" >&2 ;;
        esac
    done <"$MANIFEST"
else
    echo "No install manifest given; removing known /usr/local KiCad paths"
    rm -rf /usr/local/share/kicad
    rm -rf /usr/local/lib/kicad
    rm -f /usr/local/lib/libkicommon.so*
    rm -f /usr/local/bin/kicad /usr/local/bin/kicad-cli /usr/local/bin/eeschema \
        /usr/local/bin/pcbnew /usr/local/bin/gerbview /usr/local/bin/pl_editor \
        /usr/local/bin/pcb_calculator /usr/local/bin/bitmap2component
fi

# Prune now-empty directories without disturbing anything else under /usr/local.
rmdir --ignore-fail-on-non-empty /usr/local/share/kicad 2>/dev/null || true

ldconfig
echo "Done. /usr/local KiCad removed."
