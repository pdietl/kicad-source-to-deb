#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/elf.sh"
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

@test "an unreadable subdirectory fails the whole scan instead of silently stripping fewer files" {
    # A stage tree `find` cannot fully descend must not report success with
    # a partial count -- that is a .deb silently missing whatever lived
    # behind the unreadable directory.
    mkdir -p "$STAGE/usr/lib/secret"
    printf 'int f(void){return 0;}\n' >"$STAGE/s.c"
    gcc -g -shared -o "$STAGE/usr/lib/secret/hidden.so" "$STAGE/s.c"
    chmod 000 "$STAGE/usr/lib/secret"
    run kicad_strip_tree "$STAGE"
    chmod 755 "$STAGE/usr/lib/secret"
    [ "$status" -ne 0 ]
}

@test "an unreadable ELF file fails the scan instead of being silently skipped" {
    # `file` exits 0 even for a file it cannot read, describing it as
    # "regular file, no read permission" -- that description matches
    # neither '*ELF*' pattern, so the file would otherwise vanish from the
    # count with no error at all.
    printf 'int main(void){return 0;}\n' >"$STAGE/n.c"
    gcc -g -o "$STAGE/usr/bin/secretbin" "$STAGE/n.c"
    chmod 000 "$STAGE/usr/bin/secretbin"
    run kicad_strip_tree "$STAGE"
    chmod 644 "$STAGE/usr/bin/secretbin"
    [ "$status" -ne 0 ]
}

@test "kicad_assert_min_files accepts a tree meeting the minimum" {
    mkdir -p "$STAGE/usr/share/kicad/3dmodels/R.3dshapes"
    for i in 1 2 3; do
        echo model >"$STAGE/usr/share/kicad/3dmodels/R.3dshapes/$i.step"
    done
    run kicad_assert_min_files "$STAGE/usr/share/kicad/3dmodels" 3 "test"
    [ "$status" -eq 0 ]
}

@test "kicad_assert_min_files rejects an empty tree that dpkg-deb would happily package" {
    # Reproduces the defect verbatim: a stage tree holding only an empty
    # directory builds into a valid, useless .deb with Installed-Size: 0 and
    # rc=0 throughout -- nothing upstream of this check would ever notice.
    empty3d=$(mktemp -d)
    mkdir -p "$empty3d/usr/share/kicad/3dmodels"
    run kicad_assert_min_files "$empty3d/usr/share/kicad/3dmodels" 1000 "kicad-packages3d"
    rm -rf "$empty3d"
    [ "$status" -ne 0 ]
}

@test "kicad_assert_min_files rejects a tree with a few stray files, not just a totally empty one" {
    # A bare non-empty check (`[ -n "$(ls -A "$dir")" ]`) would pass this;
    # the point of a real minimum is that it would not.
    sparse=$(mktemp -d)
    mkdir -p "$sparse/usr/share/kicad/symbols"
    touch "$sparse/usr/share/kicad/symbols/Stray.kicad_sym"
    run kicad_assert_min_files "$sparse/usr/share/kicad/symbols" 1000 "kicad-symbols"
    rm -rf "$sparse"
    [ "$status" -ne 0 ]
}

@test "kicad_assert_min_files rejects a missing directory" {
    run kicad_assert_min_files "$STAGE/does-not-exist" 1 "test"
    [ "$status" -ne 0 ]
}

@test "a tree with no ELF files at all is rejected, not reported as zero stripped" {
    # count==0 must be indistinguishable from neither "an honestly ELF-free
    # tree" nor "the scan quietly failed" -- both are suspicious for a
    # staged KiCad tree, so both are fatal, matching kicad_shlibdeps.
    empty=$(mktemp -d)
    mkdir -p "$empty/usr/share/doc"
    echo "not an ELF file" >"$empty/usr/share/doc/readme.txt"
    run kicad_strip_tree "$empty"
    rm -rf "$empty"
    [ "$status" -ne 0 ]
}
