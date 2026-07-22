#!/usr/bin/env bash
# Staging-tree helpers: strip debug info, and split the 3D models into their
# own tree so they can ship as a separate package.
#
# Stripping matches upstream: the official AppImage build extracts debug info
# with objcopy --only-keep-debug, indexes it by build-id for debuginfod, then
# runs strip --strip-unneeded over every ELF. Debug info is ~94% of binary size.
#
# The ELF list comes from `file -N -0`, which NUL-terminates each filename
# before its description. A plain `awk -F:` split instead truncates any path
# containing a colon at the first colon, handing strip a bogus, nonexistent
# path -- which then fails silently unless every strip failure is checked.

kicad_strip_tree() {
    local dir=$1
    local count=0 failed=0 f desc

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        IFS= read -r desc
        case "$desc" in
            *'ELF'*'not stripped'*)
                if strip --strip-unneeded "$f"; then
                    count=$((count + 1))
                else
                    echo "kicad_strip_tree: strip failed on: $f" >&2
                    failed=1
                fi
                ;;
        esac
    done < <(
        find "$dir" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
            xargs -0 -r file -N -0
    )

    printf '%s\n' "$count"

    [ "$failed" -eq 0 ]
}
