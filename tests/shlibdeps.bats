#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/shlibdeps.sh"
    STAGE=$(mktemp -d)
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib"
    # A real dynamically-linked ELF with known dependencies.
    cp /bin/ls "$STAGE/usr/bin/"
}

teardown() {
    rm -rf "$STAGE"
}

@test "returns a non-empty dependency string for a real binary" {
    run kicad_shlibdeps "$STAGE"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "the dependency string names libc" {
    run kicad_shlibdeps "$STAGE"
    [[ "$output" == *libc6* ]]
}

@test "output is a single comma-separated line, not a substvars assignment" {
    run kicad_shlibdeps "$STAGE"
    [[ "$output" != *"shlibs:Depends="* ]]
    [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
}

@test "a stage tree with no ELF files fails rather than emitting empty deps" {
    empty=$(mktemp -d)
    mkdir -p "$empty/usr/bin"
    run kicad_shlibdeps "$empty"
    rm -rf "$empty"
    [ "$status" -ne 0 ]
}

@test "private libraries in the stage tree do not abort the run" {
    # A library belonging to no package is exactly what KiCad ships.
    cp /bin/ls "$STAGE/usr/lib/libkicommon.so.10.0.5"
    run kicad_shlibdeps "$STAGE"
    [ "$status" -eq 0 ]
}
