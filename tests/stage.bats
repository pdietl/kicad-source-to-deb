#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/stage.sh"
    STAGE=$(mktemp -d)
    STAGE3D=$(mktemp -d)
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes"
    # Compile a test binary with debug info to ensure we have something to strip
    printf 'int main(void){return 0;}\n' > "$STAGE/test.c"
    gcc -g -o "$STAGE/usr/bin/kicad" "$STAGE/test.c"
    echo "model" > "$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes/R.step"
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
    printf 'int main(void){return 0;}\n' > "$STAGE/t.c"
    gcc -g -o "$STAGE/usr/bin/withdebug" "$STAGE/t.c"
    before=$(stat -c %s "$STAGE/usr/bin/withdebug")
    kicad_strip_tree "$STAGE" > /dev/null
    after=$(stat -c %s "$STAGE/usr/bin/withdebug")
    [ "$after" -lt "$before" ]
}

@test "a missing directory is rejected" {
    run kicad_strip_tree "$STAGE/does-not-exist"
    [ "$status" -ne 0 ]
}
