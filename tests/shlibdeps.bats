#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/elf.sh"
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
    [ -n "$output" ]
}

@test "a non-executable dynamically-linked ELF (mode 0644, like a .kiface module) has its NEEDED libs picked up" {
    # KiCad's kiface plugin modules (_pcbnew.kiface, _eeschema.kiface,
    # _cvpcb.kiface, ...) install this way: a regular file, mode 0644, no
    # ".so" in the name, one directory deeper under usr/lib/kicad. Neither a
    # permission-based nor a name-based filter would select it, so its own
    # NEEDED entries would never reach dpkg-shlibdeps and the package's
    # Depends: would silently omit them.
    mkdir -p "$STAGE/usr/lib/kicad"
    src=$(mktemp --suffix=.c)
    echo 'extern int compress(void); int main(void) { return compress(); }' >"$src"

    if ! gcc -o "$STAGE/usr/lib/kicad/_pcbnew.kiface" "$src" -lz 2>/dev/null; then
        rm -f "$src"
        skip "zlib1g-dev unavailable; cannot build a kiface-shaped test binary"
    fi
    rm -f "$src"
    chmod 644 "$STAGE/usr/lib/kicad/_pcbnew.kiface"

    run kicad_shlibdeps "$STAGE"
    [ "$status" -eq 0 ]
    [[ "$output" == *zlib1g* ]]
}

@test "a dpkg-shlibdeps failure is not masked as success" {
    # Shim dpkg-shlibdeps ahead of the real one on PATH so it fails outright;
    # the function must surface that failure, not swallow it behind $?
    # clobbered by the later cleanup or a printf that always exits 0.
    shim_dir=$(mktemp -d)
    cat >"$shim_dir/dpkg-shlibdeps" <<'SHIM'
#!/usr/bin/env bash
echo "dpkg-shlibdeps: fatal error: shimmed failure" >&2
exit 2
SHIM
    chmod +x "$shim_dir/dpkg-shlibdeps"

    OLDPATH="$PATH"
    PATH="$shim_dir:$PATH"
    run kicad_shlibdeps "$STAGE"
    PATH="$OLDPATH"
    rm -rf "$shim_dir"

    [ "$status" -ne 0 ]
}

@test "an unreadable subdirectory fails the scan instead of computing Depends: from a partial tree" {
    # Same shared-enumerator defect as lib/stage.sh: a directory `find`
    # cannot descend into must not make kicad_shlibdeps compute Depends:
    # from fewer ELF files than the stage tree actually contains.
    mkdir -p "$STAGE/usr/lib/secret"
    cp /bin/ls "$STAGE/usr/lib/secret/hidden"
    chmod 000 "$STAGE/usr/lib/secret"
    run kicad_shlibdeps "$STAGE"
    chmod 755 "$STAGE/usr/lib/secret"
    [ "$status" -ne 0 ]
}

@test "a statically-linked ELF with no NEEDED entries fails rather than emitting empty deps" {
    static_stage=$(mktemp -d)
    mkdir -p "$static_stage/usr/bin"
    src=$(mktemp --suffix=.c)
    echo 'int main(void) { return 0; }' >"$src"

    if ! gcc -static -o "$static_stage/usr/bin/static-noop" "$src" 2>/dev/null; then
        rm -f "$src"
        rm -rf "$static_stage"
        skip "static libc unavailable; cannot build a statically-linked test binary"
    fi
    rm -f "$src"

    run kicad_shlibdeps "$static_stage"
    rm -rf "$static_stage"

    [ "$status" -ne 0 ]
}
