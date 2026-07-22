#!/usr/bin/env bash
# Decide whether a raw manifest line refers to a path actually contained in a
# prefix, before uninstall-usr-local.sh acts on it as root.
#
# A textual prefix check (`case "$f" in "$prefix"/*)`) is defeated two ways:
# a ".." traversal embedded in the manifest line (e.g.
# "$prefix/../../etc/passwd" textually starts with "$prefix/" but resolves
# elsewhere), and a symlinked intermediate path component. Both are defeated
# by resolving the path first and testing containment on the resolved form,
# not the raw text.
#
# realpath -m tolerates a target that doesn't exist, which matters here: a
# manifest may list files a previous run already removed.

# kicad_uninstall_resolve_under_prefix <raw-path> <prefix>
# On success, prints the canonical form of <raw-path> and returns 0. Returns
# 1 for a blank input or a path whose canonical form is not <prefix> itself
# or something under it.
kicad_uninstall_resolve_under_prefix() {
    local raw=$1 prefix=$2 resolved

    [ -n "$raw" ] || return 1

    resolved=$(realpath -m -- "$raw") || return 1

    case "$resolved" in
        "$prefix" | "$prefix"/*)
            printf '%s\n' "$resolved"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
