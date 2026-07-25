#!/usr/bin/env bash
# Staging-tree helpers: separate debug info from the binaries that carry it,
# and split the 3D models into their own tree so they can ship as a separate
# package.
#
# Debug info is ~96% of binary size, so it cannot stay in the main package,
# but discarding it makes every crash and hang report unreadable. Extracting
# it first matches what upstream's AppImage build does, and what Debian's
# dh_strip does for a -dbgsym package.
#
# ELF discovery is shared with lib/shlibdeps.sh -- see lib/elf.sh.

# kicad_split_debug <stage-dir> <debug-dir>
#
# Moves each ELF's debug info out to <debug-dir>/.build-id/<xx>/<rest>.debug
# and strips the original. Prints the number of files processed.
#
# The build-id layout is not decoration: it is the only way gdb finds a
# separate debug file for a stripped binary that carries no debug link, and
# it is what makes the debug package installable and removable independently
# of the binaries it describes.
kicad_split_debug() {
    local dir=$1 debugdir=$2
    local count=0 failed=0 f list bid dest

    if [ ! -d "$dir" ]; then
        echo "kicad_split_debug: no such directory: $dir" >&2
        return 1
    fi

    if [ -z "$debugdir" ]; then
        echo "kicad_split_debug: no debug output directory given" >&2
        return 1
    fi

    # A plain redirected call, not `< <(kicad_find_elf ...)`: a process
    # substitution's exit status is unobservable here, which is exactly the
    # bug class this scan already paid for once (see lib/elf.sh) -- a
    # partial enumeration must fail the whole staging step, not silently
    # strip fewer files than the tree actually contains.
    list=$(mktemp)
    if ! kicad_find_elf "$dir" '*ELF*not stripped*' >"$list"; then
        echo "kicad_split_debug: ELF enumeration under $dir failed" >&2
        rm -f "$list"
        return 1
    fi

    while IFS= read -r -d '' f; do
        bid=$(readelf -n "$f" 2>/dev/null | awk '/Build ID:/ { print $3; exit }')

        # Without a build ID there is nowhere to file the debug info that
        # anything could later look it up under, so stripping the binary
        # anyway would destroy the only copy. Refuse instead: a debug
        # package silently missing the one binary being debugged is worse
        # than a build that stops and says so.
        if [ -z "$bid" ]; then
            echo "kicad_split_debug: no build ID, cannot separate debug info: $f" >&2
            failed=1
            continue
        fi

        dest="$debugdir/.build-id/${bid:0:2}/${bid:2}.debug"
        mkdir -p "${dest%/*}"

        # Ordering is load-bearing: extract first, strip only once the
        # extraction succeeded, so a failure leaves the debug info in the
        # binary rather than nowhere.
        if ! objcopy --only-keep-debug "$f" "$dest"; then
            echo "kicad_split_debug: objcopy failed on: $f" >&2
            failed=1
            continue
        fi
        # objcopy copies the source mode, which makes debug data executable.
        chmod 0644 "$dest"

        if strip --strip-unneeded "$f"; then
            count=$((count + 1))
        else
            echo "kicad_split_debug: strip failed on: $f" >&2
            failed=1
        fi
    done <"$list"
    rm -f "$list"

    # count==0 is indistinguishable from a failed enumeration unless it is
    # itself fatal -- matching kicad_shlibdeps, which already refuses to
    # emit empty Depends: for the same reason.
    if [ "$count" -eq 0 ]; then
        echo "kicad_split_debug: no ELF files found under $dir" >&2
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
