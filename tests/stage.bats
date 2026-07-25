#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/elf.sh"
    load "${BATS_TEST_DIRNAME}/../lib/stage.sh"
    STAGE=$(mktemp -d)
    STAGE3D=$(mktemp -d)
    DEBUGDIR=$(mktemp -d)
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes"
    # Compile a test binary with debug info to ensure we have something to strip
    printf 'int main(void){return 0;}\n' >"$STAGE/test.c"
    gcc -g -o "$STAGE/usr/bin/kicad" "$STAGE/test.c"
    echo "model" >"$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes/R.step"
}

teardown() {
    rm -rf "$STAGE" "$STAGE3D" "$DEBUGDIR"
}

@test "splitting reports the number of ELF files processed" {
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
}

@test "splitting actually removes debug sections from the binary" {
    printf 'int main(void){return 0;}\n' >"$STAGE/t.c"
    gcc -g -o "$STAGE/usr/bin/withdebug" "$STAGE/t.c"
    before=$(stat -c %s "$STAGE/usr/bin/withdebug")
    kicad_split_debug "$STAGE" "$DEBUGDIR" >/dev/null
    after=$(stat -c %s "$STAGE/usr/bin/withdebug")
    [ "$after" -lt "$before" ]
}

@test "the debug info is filed under the binary's own build ID" {
    bid=$(readelf -n "$STAGE/usr/bin/kicad" | awk '/Build ID:/ { print $3; exit }')
    [ -n "$bid" ]
    kicad_split_debug "$STAGE" "$DEBUGDIR" >/dev/null
    [ -f "$DEBUGDIR/.build-id/${bid:0:2}/${bid:2}.debug" ]
}

@test "gdb resolves a function and line number through the separated debug file" {
    # The acceptance test for this whole mechanism: a stripped binary plus a
    # build-id-indexed debug file must together give back what stripping
    # took away. Anything less and the debug package is decoration.
    printf 'int helper_fn(int x){return x*2;}\nint main(void){return helper_fn(21);}\n' \
        >"$STAGE/h.c"
    gcc -g -O0 -o "$STAGE/usr/bin/withhelper" "$STAGE/h.c"
    kicad_split_debug "$STAGE" "$DEBUGDIR" >/dev/null

    run file -b "$STAGE/usr/bin/withhelper"
    [[ $output == *stripped* ]]
    [[ $output != *"not stripped"* ]]

    run gdb -batch -iex "set debug-file-directory $DEBUGDIR" \
        -ex 'info line helper_fn' "$STAGE/usr/bin/withhelper"
    [ "$status" -eq 0 ]
    [[ $output == *helper_fn* ]]
    [[ $output == *h.c* ]]
}

@test "debug files are not executable" {
    # objcopy copies the source file's mode, so debug data extracted from a
    # 0755 binary arrives executable unless something says otherwise.
    kicad_split_debug "$STAGE" "$DEBUGDIR" >/dev/null
    run find "$DEBUGDIR" -name '*.debug' -perm /111
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an ELF with no build ID fails the split instead of losing its debug info" {
    # Nothing can look up a debug file that has no build ID to file it under,
    # so stripping such a binary anyway destroys the only copy. The build has
    # to stop rather than ship a debug package quietly missing a binary.
    printf 'int main(void){return 0;}\n' >"$STAGE/nb.c"
    gcc -g -Wl,--build-id=none -o "$STAGE/usr/bin/nobuildid" "$STAGE/nb.c"
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
    [ "$status" -ne 0 ]
    [[ $output == *"no build ID"* ]]
    # and the binary keeps its debug info rather than being stripped anyway
    run file -b "$STAGE/usr/bin/nobuildid"
    [[ $output == *"not stripped"* ]]
}

@test "a missing debug output directory argument is rejected" {
    run kicad_split_debug "$STAGE" ""
    [ "$status" -ne 0 ]
}

@test "a missing directory is rejected" {
    run kicad_split_debug "$STAGE/does-not-exist" "$DEBUGDIR"
    [ "$status" -ne 0 ]
}

@test "a strip failure is reported, not swallowed as success" {
    # An unwritable-but-executable file is a realistic staged-permissions
    # case: strip can read and identify it but cannot write the result back.
    printf 'int main(void){return 0;}\n' >"$STAGE/u.c"
    gcc -g -o "$STAGE/usr/bin/unwritable" "$STAGE/u.c"
    chmod 555 "$STAGE/usr/bin/unwritable"
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
    [ "$status" -ne 0 ]
}

@test "a non-executable ELF (mode 0644, like a .kiface module) is split and counted" {
    # KiCad's plugin modules (_pcbnew.kiface, _eeschema.kiface, ...) install
    # this way: a regular file, no execute bit, no ".so" in the name.
    printf 'int main(void){return 0;}\n' >"$STAGE/m.c"
    gcc -g -o "$STAGE/usr/bin/_pcbnew.kiface" "$STAGE/m.c"
    chmod 644 "$STAGE/usr/bin/_pcbnew.kiface"
    before=$(stat -c %s "$STAGE/usr/bin/_pcbnew.kiface")
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    after=$(stat -c %s "$STAGE/usr/bin/_pcbnew.kiface")
    [ "$after" -lt "$before" ]
}

@test "a filename containing a colon is still split and counted" {
    printf 'int main(void){return 0;}\n' >"$STAGE/c.c"
    gcc -g -o "$STAGE/usr/bin/kicad:helper" "$STAGE/c.c"
    before=$(stat -c %s "$STAGE/usr/bin/kicad:helper")
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
    [ "$status" -eq 0 ]
    # setup's "kicad" plus this test's "kicad:helper" both need splitting.
    [ "$output" -ge 2 ]
    after=$(stat -c %s "$STAGE/usr/bin/kicad:helper")
    [ "$after" -lt "$before" ]
}

@test "an unreadable subdirectory fails the whole scan instead of silently splitting fewer files" {
    # A stage tree `find` cannot fully descend must not report success with
    # a partial count -- that is a .deb silently missing whatever lived
    # behind the unreadable directory.
    mkdir -p "$STAGE/usr/lib/secret"
    printf 'int f(void){return 0;}\n' >"$STAGE/s.c"
    gcc -g -shared -o "$STAGE/usr/lib/secret/hidden.so" "$STAGE/s.c"
    chmod 000 "$STAGE/usr/lib/secret"
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
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
    run kicad_split_debug "$STAGE" "$DEBUGDIR"
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

@test "a tree with no ELF files at all is rejected, not reported as zero split" {
    # count==0 must be indistinguishable from neither "an honestly ELF-free
    # tree" nor "the scan quietly failed" -- both are suspicious for a
    # staged KiCad tree, so both are fatal, matching kicad_shlibdeps.
    empty=$(mktemp -d)
    mkdir -p "$empty/usr/share/doc"
    echo "not an ELF file" >"$empty/usr/share/doc/readme.txt"
    run kicad_split_debug "$empty" "$DEBUGDIR"
    rm -rf "$empty"
    [ "$status" -ne 0 ]
}

@test "the helpers survive set -u when called the way the build script calls them" {
    # Regression: build-kicad-deb.sh runs under `set -Eeuo pipefail` and calls
    # these helpers from inside functions. A scan helper that leaves shell
    # state behind (a stray RETURN trap naming one of its own locals) is
    # invisible here -- bats runs tests without `set -u` -- but aborts the
    # real build at the first return after the scan. Reproduce the caller's
    # actual shell options rather than trusting the suite's.
    run bash -c '
        set -Eeuo pipefail
        . "$1/lib/elf.sh"
        . "$1/lib/stage.sh"
        tree=$2
        debug=$3
        outer() { kicad_split_debug "$tree" "$debug" >/dev/null; }
        outer
        echo REACHED_END
    ' _ "$BATS_TEST_DIRNAME/.." "$STAGE" "$DEBUGDIR"
    [ "$status" -eq 0 ]
    [[ $output == *REACHED_END* ]]
}
