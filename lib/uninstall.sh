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

# kicad_uninstall_process_manifest <manifest> <prefix>
#
# Removes every path listed in <manifest> that resolves under <prefix>,
# via kicad_uninstall_resolve_under_prefix. Lives here rather than inline in
# uninstall-usr-local.sh so it is one function, exercised the same way by
# the real script and by the test suite -- a bats test that instead pastes
# a copy of this loop into `bash -c` tests the copy, not the script, and
# stops catching a regression here the moment the two drift.
#
# `while IFS= read -r f; do` alone silently drops a manifest's final line
# when it lacks a trailing newline: `read` returns non-zero at EOF even
# though it already populated $f. `|| [ -n "$f" ]` catches that last line
# too.
#
# The caller is responsible for confirming <manifest> is readable first.
# Returns 1 if any line resolved outside <prefix>; blank lines are skipped.
kicad_uninstall_process_manifest() {
    local manifest=$1 prefix=$2
    local f resolved rejected=0

    while IFS= read -r f || [ -n "$f" ]; do
        [ -n "$f" ] || continue
        if resolved=$(kicad_uninstall_resolve_under_prefix "$f" "$prefix"); then
            rm -f "$resolved"
        else
            echo "  rejecting out-of-prefix path: $f" >&2
            rejected=1
        fi
    done <"$manifest"

    [ "$rejected" -eq 0 ]
}

# kicad_uninstall_remove_desktop_integration <prefix>
#
# PATH shadowing isn't the only way a source install under <prefix> outlives
# its uninstall: XDG_DATA_DIRS puts "$prefix/share" ahead of "/usr/share"
# (e.g. "/usr/local/share/:/usr/share/:..."), so a stale desktop entry, icon
# or MIME definition left under <prefix> keeps winning over the one the .deb
# installs, even after the executables are gone -- the desktop environment
# still shows an entry whose Exec=kicad now resolves through PATH to nothing.
#
# "$prefix/share/applications", ".../icons/hicolor", ".../mime/packages" and
# the completion directories are shared with other locally-installed
# software, so only the exact files KiCad's own install places there are
# removed here, by name; the containing directories are never touched.
# "$prefix/share/kicad" is KiCad-exclusive and is removed wholesale by the
# caller instead.
kicad_uninstall_remove_desktop_integration() {
    local prefix=$1 size scalable mimetype

    rm -f "$prefix"/share/applications/org.kicad.kicad.desktop \
        "$prefix"/share/applications/org.kicad.eeschema.desktop \
        "$prefix"/share/applications/org.kicad.gerbview.desktop \
        "$prefix"/share/applications/org.kicad.pcbnew.desktop \
        "$prefix"/share/applications/org.kicad.pcbcalculator.desktop \
        "$prefix"/share/applications/org.kicad.bitmap2component.desktop

    for size in 16x16 24x24 32x32 48x48 64x64 128x128; do
        [ -d "$prefix/share/icons/hicolor/$size" ] || continue
        rm -f "$prefix/share/icons/hicolor/$size"/apps/kicad.png \
            "$prefix/share/icons/hicolor/$size"/apps/eeschema.png \
            "$prefix/share/icons/hicolor/$size"/apps/gerbview.png \
            "$prefix/share/icons/hicolor/$size"/apps/pcbnew.png \
            "$prefix/share/icons/hicolor/$size"/apps/pcbcalculator.png \
            "$prefix/share/icons/hicolor/$size"/apps/bitmap2component.png
        rm -f "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-footprint.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-pcb.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-project.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-schematic.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-symbol.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-worksheet.png
    done

    scalable="$prefix/share/icons/hicolor/scalable"
    if [ -d "$scalable" ]; then
        rm -f "$scalable"/apps/kicad.svg "$scalable"/apps/eeschema.svg \
            "$scalable"/apps/gerbview.svg "$scalable"/apps/pcbnew.svg \
            "$scalable"/apps/pcbcalculator.svg "$scalable"/apps/bitmap2component.svg
        for mimetype in footprint pcb project schematic symbol worksheet; do
            rm -f "$scalable/mimetypes/application-x-kicad-$mimetype.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-16.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-24.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-32.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-48.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-64.svg"
        done
    fi

    rm -f "$prefix"/share/mime/packages/kicad-gerbers.xml \
        "$prefix"/share/mime/packages/kicad-kicad.xml

    rm -f "$prefix"/share/metainfo/org.kicad.kicad.metainfo.xml

    rm -f "$prefix"/share/bash-completion/completions/kicad-cli \
        "$prefix"/share/zsh/site-functions/_kicad-cli
}
