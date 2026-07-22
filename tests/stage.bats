#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/stage.sh"
    STAGE=$(mktemp -d)
    STAGE3D=$(mktemp -d)
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes"
    # Compile a test binary with debug info to ensure we have something to strip
    printf 'int main(void){return 0;}\n' >"$STAGE/test.c"
    gcc -g -o "$STAGE/usr/bin/kicad" "$STAGE/test.c"
    echo "model" >"$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes/R.step"
}

teardown() {
    rm -rf "$STAGE" "$STAGE3D"
}

@test "stripping reports the number of ELF files processed" {
    run kicad_strip_tree "$STAGE"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "stripping actually removes debug sections" {
    # Build an object that definitely carries debug info.
    printf 'int main(void){return 0;}\n' >"$STAGE/t.c"
    gcc -g -o "$STAGE/usr/bin/withdebug" "$STAGE/t.c"
    before=$(stat -c %s "$STAGE/usr/bin/withdebug")
    kicad_strip_tree "$STAGE" >/dev/null
    after=$(stat -c %s "$STAGE/usr/bin/withdebug")
    [ "$after" -lt "$before" ]
}

@test "a missing directory is rejected" {
    run kicad_strip_tree "$STAGE/does-not-exist"
    [ "$status" -ne 0 ]
}

@test "a strip failure is reported, not swallowed as success" {
    # An unwritable-but-executable file is a realistic staged-permissions
    # case: strip can read and identify it but cannot write the result back.
    printf 'int main(void){return 0;}\n' >"$STAGE/u.c"
    gcc -g -o "$STAGE/usr/bin/unwritable" "$STAGE/u.c"
    chmod 555 "$STAGE/usr/bin/unwritable"
    run kicad_strip_tree "$STAGE"
    [ "$status" -ne 0 ]
}

@test "a non-executable ELF (mode 0644, like a .kiface module) is stripped and counted" {
    # KiCad's plugin modules (_pcbnew.kiface, _eeschema.kiface, ...) install
    # this way: a regular file, no execute bit, no ".so" in the name.
    printf 'int main(void){return 0;}\n' >"$STAGE/m.c"
    gcc -g -o "$STAGE/usr/bin/_pcbnew.kiface" "$STAGE/m.c"
    chmod 644 "$STAGE/usr/bin/_pcbnew.kiface"
    before=$(stat -c %s "$STAGE/usr/bin/_pcbnew.kiface")
    run kicad_strip_tree "$STAGE"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    after=$(stat -c %s "$STAGE/usr/bin/_pcbnew.kiface")
    [ "$after" -lt "$before" ]
}

@test "a filename containing a colon is still stripped and counted" {
    printf 'int main(void){return 0;}\n' >"$STAGE/c.c"
    gcc -g -o "$STAGE/usr/bin/kicad:helper" "$STAGE/c.c"
    before=$(stat -c %s "$STAGE/usr/bin/kicad:helper")
    run kicad_strip_tree "$STAGE"
    [ "$status" -eq 0 ]
    # setup's "kicad" plus this test's "kicad:helper" both need stripping.
    [ "$output" -ge 2 ]
    after=$(stat -c %s "$STAGE/usr/bin/kicad:helper")
    [ "$after" -lt "$before" ]
}
