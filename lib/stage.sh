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
    local count=0 failed=0 f list

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    # A plain redirected call, not `< <(kicad_find_elf ...)`: a process
    # substitution's exit status is unobservable here, which is exactly the
    # bug class this scan already paid for once (see lib/elf.sh) -- a
    # partial enumeration must fail the whole staging step, not silently
    # strip fewer files than the tree actually contains.
    list=$(mktemp)
    if ! kicad_find_elf "$dir" '*ELF*not stripped*' >"$list"; then
        echo "kicad_strip_tree: ELF enumeration under $dir failed" >&2
        rm -f "$list"
        return 1
    fi

    while IFS= read -r -d '' f; do
        if strip --strip-unneeded "$f"; then
            count=$((count + 1))
        else
            echo "kicad_strip_tree: strip failed on: $f" >&2
            failed=1
        fi
    done <"$list"
    rm -f "$list"

    # count==0 is indistinguishable from a failed enumeration unless it is
    # itself fatal -- matching kicad_shlibdeps, which already refuses to
    # emit empty Depends: for the same reason.
    if [ "$count" -eq 0 ]; then
        echo "kicad_strip_tree: no ELF files found under $dir" >&2
        return 1
    fi

    printf '%s\n' "$count"

    [ "$failed" -eq 0 ]
}

# kicad_assert_min_files <dir> <min-count> <label>
#
# A staging step that silently produces an empty or near-empty tree still
# passes `dpkg-deb --build` and yields an installable, useless package with
# a plausible-looking control file -- an empty kicad-packages3d tree has
# been built this way, `Installed-Size: 0` and all, rc=0 throughout. A bare
# non-empty check (`[ -n "$(ls -A "$dir")" ]`) is not enough to catch this:
# it accepts a tree holding a single stray file just as happily as a real
# install. <min-count> is chosen well below what a real staging step
# produces, so this never trips on legitimate variance, and well above
# zero, so a step that installed almost nothing is caught immediately
# rather than shipped.
kicad_assert_min_files() {
    local dir=$1 min=$2 label=$3
    local count

    if [ ! -d "$dir" ]; then
        echo "kicad_assert_min_files: $label: no such directory: $dir" >&2
        return 1
    fi

    count=$(find "$dir" -type f | wc -l)
    if [ "$count" -lt "$min" ]; then
        echo "kicad_assert_min_files: $label: only $count file(s) under" \
            "$dir, expected at least $min" >&2
        return 1
    fi
}
