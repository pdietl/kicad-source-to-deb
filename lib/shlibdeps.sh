#!/usr/bin/env bash
# Compute a Depends: value from the ELF files in a staging tree.
#
# dpkg-shlibdeps has two behaviours that make it awkward outside a Debian source
# package, both confirmed by running it:
#   - it refuses to start without a debian/control file, so one is synthesised;
#   - it treats a library belonging to no package as fatal, which is exactly what
#     KiCad's own libkicommon.so is, so -l points it at the staged lib directory
#     and --ignore-missing-info downgrades the failure. KiCad also installs its
#     kiface plugin modules a directory deeper, under usr/lib/kicad, so that path
#     is added too -- without it those modules' own NEEDED libs go unresolved.
#
# The ELF list comes from `file -N -0`, which NUL-terminates each filename
# before its description. A plain `awk -F:` split instead truncates any path
# containing a colon at the first colon, feeding dpkg-shlibdeps a bogus path.

kicad_shlibdeps() {
    local stage=$1
    local workdir out err rc f desc
    local elves=()

    if [ ! -d "$stage" ]; then
        echo "kicad_shlibdeps: no such stage directory: $stage" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        IFS= read -r desc
        case "$desc" in
            *'ELF'*)
                elves+=("$f")
                ;;
        esac
    done < <(
        find "$stage" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
            xargs -0 -r file -N -0
    )

    if [ ${#elves[@]} -eq 0 ]; then
        echo "kicad_shlibdeps: no ELF files found under $stage" >&2
        return 1
    fi

    workdir=$(mktemp -d)
    mkdir -p "$workdir/debian"
    printf 'Source: kicad\n\nPackage: kicad\nArchitecture: amd64\n' \
        >"$workdir/debian/control"

    err=$(mktemp)
    out=$(
        cd "$workdir" &&
            dpkg-shlibdeps -O --ignore-missing-info \
                -l"$stage/usr/lib" \
                -l"$stage/usr/lib/kicad" \
                "${elves[@]}" 2>"$err"
    )
    rc=$?
    rm -rf "$workdir"

    if [ "$rc" -ne 0 ]; then
        echo "kicad_shlibdeps: dpkg-shlibdeps failed for $stage:" >&2
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"

    # -O prints "shlibs:Depends=a, b, c"; callers want just the value.
    out=${out#shlibs:Depends=}

    if [ -z "$out" ]; then
        echo "kicad_shlibdeps: dpkg-shlibdeps produced no dependencies for $stage" >&2
        return 1
    fi

    printf '%s\n' "$out"
}
