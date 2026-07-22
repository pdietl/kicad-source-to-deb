#!/usr/bin/env bash
# Compute a Depends: value from the ELF files in a staging tree.
#
# dpkg-shlibdeps has two behaviours that make it awkward outside a Debian source
# package, both confirmed by running it:
#   - it refuses to start without a debian/control file, so one is synthesised;
#   - it treats a library belonging to no package as fatal, which is exactly what
#     KiCad's own libkicommon.so and libkiapi.so are, so -l points it at the
#     directories holding them and --ignore-missing-info downgrades the failure.
#
# Those -l directories are discovered from the tree rather than named. -l does
# not recurse, and the layout is not one path: the shared libraries land under
# the multiarch triplet (usr/lib/x86_64-linux-gnu), the 3D plugins deeper still,
# and the kiface modules in usr/bin. A named path that stops matching the layout
# contributes nothing and reports nothing, leaving dpkg-shlibdeps unable to
# resolve the package's own libraries -- the same failure that comes of guessing
# at ELF files by name or permission instead of asking what they are.
#
# ELF discovery is shared with lib/stage.sh -- see lib/elf.sh. Every regular
# file is tested, not just executable ones or ones named *.so*: those kiface
# modules install mode 0644 with no ".so" in the name, so a permission- or
# name-based filter never sees them, and their own NEEDED libraries never
# reach dpkg-shlibdeps.

kicad_shlibdeps() {
    local stage=$1
    local workdir out err rc f d list
    local elves=() libdirs=()
    local -A seen=()

    if [ ! -d "$stage" ]; then
        echo "kicad_shlibdeps: no such stage directory: $stage" >&2
        return 1
    fi

    # A plain redirected call, not `< <(kicad_find_elf ...)`: a process
    # substitution's exit status is unobservable here, which is exactly the
    # bug class this scan already paid for once (see lib/elf.sh) -- a
    # partial enumeration must fail the whole dependency computation, not
    # silently compute Depends: from fewer ELF files than the tree actually
    # contains.
    list=$(mktemp)
    if ! kicad_find_elf "$stage" '*ELF*' >"$list"; then
        echo "kicad_shlibdeps: ELF enumeration under $stage failed" >&2
        rm -f "$list"
        return 1
    fi

    while IFS= read -r -d '' f; do
        elves+=("$f")
    done <"$list"
    rm -f "$list"

    if [ ${#elves[@]} -eq 0 ]; then
        echo "kicad_shlibdeps: no ELF files found under $stage" >&2
        return 1
    fi

    # Selecting on the description rather than filtering $elves by name keeps
    # PIE executables out ("pie executable", not "shared object") while still
    # catching the kiface modules, which are shared objects with neither a
    # .so name nor the executable bit.
    list=$(mktemp)
    if ! kicad_find_elf "$stage" '*ELF*shared object*' >"$list"; then
        echo "kicad_shlibdeps: shared-object enumeration under $stage failed" >&2
        rm -f "$list"
        return 1
    fi

    while IFS= read -r -d '' f; do
        d=$(dirname "$f")
        if [ -z "${seen[$d]:-}" ]; then
            seen[$d]=1
            libdirs+=("-l$d")
        fi
    done <"$list"
    rm -f "$list"

    # No shared objects means no -l is needed, which is a legitimate tree, not
    # an error: dpkg-shlibdeps stays the authority on what it cannot resolve
    # and fails loudly on a library it cannot place.
    workdir=$(mktemp -d)
    mkdir -p "$workdir/debian"
    printf 'Source: kicad\n\nPackage: kicad\nArchitecture: amd64\n' \
        >"$workdir/debian/control"

    err=$(mktemp)
    out=$(
        cd "$workdir" &&
            dpkg-shlibdeps -O --ignore-missing-info \
                "${libdirs[@]}" "${elves[@]}" 2>"$err"
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
