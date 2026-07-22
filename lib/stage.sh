#!/usr/bin/env bash
# Staging-tree helpers: strip debug info, and split the 3D models into their
# own tree so they can ship as a separate package.
#
# Stripping matches upstream: the official AppImage build extracts debug info
# with objcopy --only-keep-debug, indexes it by build-id for debuginfod, then
# runs strip --strip-unneeded over every ELF. Debug info is ~94% of binary size.
#
# ELF discovery is shared with lib/shlibdeps.sh -- see lib/elf.sh.

kicad_strip_tree() {
    local dir=$1
    local count=0 failed=0 f

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        if strip --strip-unneeded "$f"; then
            count=$((count + 1))
        else
            echo "kicad_strip_tree: strip failed on: $f" >&2
            failed=1
        fi
    done < <(kicad_find_elf "$dir" '*ELF*not stripped*')

    printf '%s\n' "$count"

    [ "$failed" -eq 0 ]
}
