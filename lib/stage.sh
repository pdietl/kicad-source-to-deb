#!/usr/bin/env bash
# Staging-tree helpers: strip debug info, and split the 3D models into their
# own tree so they can ship as a separate package.
#
# Stripping matches upstream: the official AppImage build extracts debug info
# with objcopy --only-keep-debug, indexes it by build-id for debuginfod, then
# runs strip --strip-unneeded over every ELF. Debug info is ~94% of binary size.

kicad_strip_tree() {
    local dir=$1
    local count=0 f

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    while IFS= read -r f; do
        strip --strip-unneeded "$f" 2>/dev/null && count=$((count + 1))
    done < <(
        find "$dir" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
            xargs -0 -r file -N |
            awk -F: '/ELF.*not stripped/{print $1}'
    )

    printf '%s\n' "$count"
}
