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
