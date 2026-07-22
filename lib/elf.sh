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

# kicad_find_elf <dir> <desc-glob>
# Prints NUL-terminated paths of every regular file under <dir> whose `file`
# description matches the glob <desc-glob> (e.g. '*ELF*', or
# '*ELF*not stripped*' to select only unstripped ELF files).
kicad_find_elf() {
    local dir=$1 pattern=$2
    local f desc

    while IFS= read -r -d '' f; do
        IFS= read -r desc
        # shellcheck disable=SC2254 # unquoted on purpose: caller-supplied glob
        case "$desc" in
            $pattern)
                printf '%s\0' "$f"
                ;;
        esac
    done < <(
        find "$dir" -type f -print0 |
            xargs -0 -r file -N -0
    )
}
