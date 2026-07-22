#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/uninstall.sh"
    PREFIX=$(mktemp -d)
    mkdir -p "$PREFIX/bin" "$PREFIX/share/kicad"
}

teardown() {
    rm -rf "$PREFIX"
    [ -z "${OUTSIDE:-}" ] || rm -rf "$OUTSIDE"
}

@test "a normal path under the prefix is accepted" {
    run kicad_uninstall_resolve_under_prefix "$PREFIX/bin/kicad" "$PREFIX"
    [ "$status" -eq 0 ]
    [ "$output" = "$PREFIX/bin/kicad" ]
}

@test "the prefix itself is accepted" {
    run kicad_uninstall_resolve_under_prefix "$PREFIX" "$PREFIX"
    [ "$status" -eq 0 ]
    [ "$output" = "$PREFIX" ]
}

@test "a .. traversal escaping the prefix is rejected" {
    run kicad_uninstall_resolve_under_prefix "$PREFIX/share/kicad/../../../etc/passwd" "$PREFIX"
    [ "$status" -ne 0 ]
}

@test "a path outside the prefix is rejected" {
    OUTSIDE=$(mktemp -d)
    run kicad_uninstall_resolve_under_prefix "$OUTSIDE/etc/passwd" "$PREFIX"
    [ "$status" -ne 0 ]
}

@test "a blank line is skipped" {
    run kicad_uninstall_resolve_under_prefix "" "$PREFIX"
    [ "$status" -ne 0 ]
}

@test "a sibling path that merely shares the prefix string is rejected" {
    # "$PREFIX-evil" starts with the literal text "$PREFIX" but is a
    # different, sibling directory -- a naive `case "$resolved" in
    # "$prefix"*)` (no slash) would wrongly accept it.
    run kicad_uninstall_resolve_under_prefix "${PREFIX}-evil/passwd" "$PREFIX"
    [ "$status" -ne 0 ]
}

@test "a symlinked intermediate component escaping the prefix is rejected" {
    OUTSIDE=$(mktemp -d)
    echo secret >"$OUTSIDE/passwd"
    ln -s "$OUTSIDE" "$PREFIX/escape"
    run kicad_uninstall_resolve_under_prefix "$PREFIX/escape/passwd" "$PREFIX"
    [ "$status" -ne 0 ]
}

@test "a nonexistent path under the prefix is still accepted (already-removed manifest entry)" {
    run kicad_uninstall_resolve_under_prefix "$PREFIX/bin/already-gone" "$PREFIX"
    [ "$status" -eq 0 ]
    [ "$output" = "$PREFIX/bin/already-gone" ]
}

@test "desktop-integration removal is a no-op without error on an empty prefix" {
    run kicad_uninstall_remove_desktop_integration "$PREFIX"
    [ "$status" -eq 0 ]
}

@test "desktop-integration removal deletes KiCad's own files and leaves other software's files alone" {
    # applications/, icons/hicolor/, mime/packages/ and the completion dirs
    # are shared with whatever else is installed under this prefix -- seed
    # each with a KiCad file alongside a decoy belonging to another package,
    # and assert only the KiCad file is removed.
    mkdir -p "$PREFIX/share/applications"
    touch "$PREFIX/share/applications/org.kicad.kicad.desktop" \
        "$PREFIX/share/applications/org.kicad.eeschema.desktop" \
        "$PREFIX/share/applications/other-app.desktop"

    mkdir -p "$PREFIX/share/icons/hicolor/128x128/apps" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes" \
        "$PREFIX/share/icons/hicolor/scalable/apps" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes"
    touch "$PREFIX/share/icons/hicolor/128x128/apps/kicad.png" \
        "$PREFIX/share/icons/hicolor/128x128/apps/other-app.png" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-kicad-pcb.png" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-other-mime.png" \
        "$PREFIX/share/icons/hicolor/scalable/apps/kicad.svg" \
        "$PREFIX/share/icons/hicolor/scalable/apps/other-app.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb-16.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-other-mime.svg"

    mkdir -p "$PREFIX/share/mime/packages"
    touch "$PREFIX/share/mime/packages/kicad-kicad.xml" \
        "$PREFIX/share/mime/packages/kicad-gerbers.xml" \
        "$PREFIX/share/mime/packages/other-app.xml"

    mkdir -p "$PREFIX/share/metainfo"
    touch "$PREFIX/share/metainfo/org.kicad.kicad.metainfo.xml" \
        "$PREFIX/share/metainfo/org.other-app.metainfo.xml"

    mkdir -p "$PREFIX/share/bash-completion/completions" "$PREFIX/share/zsh/site-functions"
    touch "$PREFIX/share/bash-completion/completions/kicad-cli" \
        "$PREFIX/share/bash-completion/completions/other-tool" \
        "$PREFIX/share/zsh/site-functions/_kicad-cli" \
        "$PREFIX/share/zsh/site-functions/_other-tool"

    kicad_uninstall_remove_desktop_integration "$PREFIX"

    # KiCad's own files are gone.
    [ ! -e "$PREFIX/share/applications/org.kicad.kicad.desktop" ]
    [ ! -e "$PREFIX/share/applications/org.kicad.eeschema.desktop" ]
    [ ! -e "$PREFIX/share/icons/hicolor/128x128/apps/kicad.png" ]
    [ ! -e "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-kicad-pcb.png" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/apps/kicad.svg" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb.svg" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb-16.svg" ]
    [ ! -e "$PREFIX/share/mime/packages/kicad-kicad.xml" ]
    [ ! -e "$PREFIX/share/mime/packages/kicad-gerbers.xml" ]
    [ ! -e "$PREFIX/share/metainfo/org.kicad.kicad.metainfo.xml" ]
    [ ! -e "$PREFIX/share/bash-completion/completions/kicad-cli" ]
    [ ! -e "$PREFIX/share/zsh/site-functions/_kicad-cli" ]

    # Files belonging to other, unrelated software survive untouched.
    [ -e "$PREFIX/share/applications/other-app.desktop" ]
    [ -e "$PREFIX/share/icons/hicolor/128x128/apps/other-app.png" ]
    [ -e "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-other-mime.png" ]
    [ -e "$PREFIX/share/icons/hicolor/scalable/apps/other-app.svg" ]
    [ -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-other-mime.svg" ]
    [ -e "$PREFIX/share/mime/packages/other-app.xml" ]
    [ -e "$PREFIX/share/metainfo/org.other-app.metainfo.xml" ]
    [ -e "$PREFIX/share/bash-completion/completions/other-tool" ]
    [ -e "$PREFIX/share/zsh/site-functions/_other-tool" ]

    # The shared containing directories themselves are never removed.
    [ -d "$PREFIX/share/applications" ]
    [ -d "$PREFIX/share/icons/hicolor" ]
    [ -d "$PREFIX/share/mime/packages" ]
    [ -d "$PREFIX/share/bash-completion/completions" ]
    [ -d "$PREFIX/share/zsh/site-functions" ]
}
