#!/usr/bin/env bash
# Enumerate ELF files under a directory tree by asking `file` what each
# regular file actually is, not by guessing from its name or permission
# bits. KiCad's kiface plugin modules (_pcbnew.kiface, _eeschema.kiface,
# _cvpcb.kiface, _gerbview.kiface, _kipython.kiface, _pcb_calculator.kiface,
# _pl_editor.kiface) install mode 0644 with no ".so" in the name and carry
# the bulk of KiCad's code, so a permission- or name-based filter
# (`-perm -u+x -o -name '*.so*'`) misses every one of them -- both when
# stripping debug info and when computing shared-library dependencies, so
# both callers share this scan rather than each re-deriving their own
# `find`/`file` predicate that could drift out of agreement.
#
# `file -N -0` NUL-terminates each filename before its description; a plain
# `awk -F:` split instead truncates any path containing a colon at the first
# colon, handing the caller a bogus, nonexistent path.
#
# A directory `find` cannot descend into makes the enumeration partial, and
# a file `file` cannot open makes it partial in a way that produces no error
# at all -- `file` prints "regular file, no read permission" for such a file
# and still exits 0. Both must abort the scan rather than silently return
# fewer paths than the tree actually contains: a caller computing Depends:
# or deciding what to strip from a partial list ships a package short of
# whatever lived on the unreadable side. `find | xargs file` is therefore
# run as a plain pipeline into a scratch file, not `< <(...)`, so its exit
# statuses land in PIPESTATUS where the caller can act on them -- a process
# substitution's exit status is never examined, and `pipefail` does not
# reach into one.

# kicad_find_elf <dir> <desc-glob>
# Prints NUL-terminated paths of every regular file under <dir> whose `file`
# description matches the glob <desc-glob> (e.g. '*ELF*', or
# '*ELF*not stripped*' to select only unstripped ELF files). Returns 1,
# printing nothing further, if the underlying scan was partial: `find`
# failed to descend somewhere, `file` itself failed, or `file` reported a
# file it could not read.
kicad_find_elf() {
    local scratch rc

    # The scan proper runs in a helper so this wrapper owns the scratch file
    # outright: one creation, one removal, on every path out of the helper --
    # including its early returns, which is what a cleanup repeated before
    # each `return` gets wrong as soon as a new one is added. A `trap ...
    # RETURN` would express the same intent in one line, but a RETURN trap is
    # global rather than function-scoped: it survives the return that fires
    # it and fires again when the *caller* returns, by which point the local
    # it names is out of scope and `set -u` aborts the run.
    scratch=$(mktemp)
    kicad_find_elf_scan "$1" "$2" "$scratch"
    rc=$?
    rm -f "$scratch"
    return "$rc"
}

# Internal: the scan itself, writing its intermediate `file` output to the
# caller-supplied <scratch> path. Split out only so kicad_find_elf can own
# that file's lifetime; not part of the interface.
kicad_find_elf_scan() {
    local dir=$1 pattern=$2 scratch=$3
    local f desc
    local pipe_rc=()

    find "$dir" -type f -print0 | xargs -0 -r file -N -0 >"$scratch"
    # Both elements must be captured in this one statement: reading
    # PIPESTATUS a second time (e.g. a separate `rc_file=${PIPESTATUS[1]}`
    # assignment) already reset it to reflect that assignment's own status.
    pipe_rc=("${PIPESTATUS[@]}")
    if [ "${pipe_rc[0]}" -ne 0 ] || [ "${pipe_rc[1]}" -ne 0 ]; then
        echo "kicad_find_elf: scan under $dir was incomplete" \
            "(find rc=${pipe_rc[0]}, file rc=${pipe_rc[1]})" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        IFS= read -r desc
        # shellcheck disable=SC2254 # unquoted on purpose: caller-supplied glob
        case "$desc" in
            *'no read permission'*)
                echo "kicad_find_elf: cannot read $f -- scan is incomplete" >&2
                return 1
                ;;
            $pattern)
                printf '%s\0' "$f"
                ;;
        esac
    done <"$scratch"
}
