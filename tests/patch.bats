#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/patch.sh"
    REPO=$(mktemp -d)
    PATCHES=$(mktemp -d)

    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name test
    printf 'one\ntwo\nthree\n' >"$REPO/file.txt"
    git -C "$REPO" add file.txt
    git -C "$REPO" commit -qm initial

    # Author the patch the way the real ones are authored: edit the tree,
    # capture the diff, restore the tree.
    printf 'one\nTWO\nthree\n' >"$REPO/file.txt"
    git -C "$REPO" diff >"$PATCHES/0001-upper.patch"
    git -C "$REPO" checkout -q -- file.txt
}

teardown() {
    rm -rf "$REPO" "$PATCHES"
}

@test "a patch that is missing from the tree is applied" {
    run kicad_apply_patches "$PATCHES" "$REPO"
    [ "$status" -eq 0 ]
    [[ $output == *"applied  0001-upper.patch"* ]]
    grep -q TWO "$REPO/file.txt"
}

@test "re-applying is a no-op, not a failure -- west update leaves the tree patched" {
    kicad_apply_patches "$PATCHES" "$REPO"
    run kicad_apply_patches "$PATCHES" "$REPO"
    [ "$status" -eq 0 ]
    [[ $output == *"present  0001-upper.patch"* ]]
    # Still applied exactly once, not doubled.
    [ "$(grep -c TWO "$REPO/file.txt")" -eq 1 ]
}

@test "a patch that neither applies nor is already applied is a hard error" {
    # Simulates the upstream bump case: the context the patch expects is gone.
    printf 'completely\ndifferent\ncontent\n' >"$REPO/file.txt"
    run kicad_apply_patches "$PATCHES" "$REPO"
    [ "$status" -ne 0 ]
    [[ $output == *"does not apply"* ]]
}

@test "an empty patch directory is rejected, not reported as success" {
    # A patch set that silently shrank to nothing still builds, and ships
    # every defect the patches existed to fix.
    empty=$(mktemp -d)
    run kicad_apply_patches "$empty" "$REPO"
    rmdir "$empty"
    [ "$status" -ne 0 ]
}

@test "a missing patch directory is rejected" {
    run kicad_apply_patches "$PATCHES/does-not-exist" "$REPO"
    [ "$status" -ne 0 ]
}

@test "a target that is not a git checkout is rejected" {
    plain=$(mktemp -d)
    run kicad_apply_patches "$PATCHES" "$plain"
    rmdir "$plain"
    [ "$status" -ne 0 ]
}

@test "patches are applied in sorted order, not filesystem order" {
    # 0002 must be authored on top of 0001, so it is generated from a commit
    # that already carries 0001 -- diffing an unstaged tree would produce a
    # patch against the pristine file instead, which overlaps 0001 rather than
    # following it.
    base=$(git -C "$REPO" rev-parse HEAD)
    git -C "$REPO" apply "$PATCHES/0001-upper.patch"
    git -C "$REPO" commit -qam "0001 applied"
    printf 'one\nTWO\nTHREE\n' >"$REPO/file.txt"
    git -C "$REPO" diff >"$PATCHES/0002-upper-three.patch"
    git -C "$REPO" reset -q --hard "$base"

    run kicad_apply_patches "$PATCHES" "$REPO"
    [ "$status" -eq 0 ]
    grep -q THREE "$REPO/file.txt"

    # And the dependency is real: 0002 alone does not apply to a pristine tree,
    # so a run that ignored ordering could not have succeeded above.
    git -C "$REPO" reset -q --hard "$base"
    run git -C "$REPO" apply --check "$PATCHES/0002-upper-three.patch"
    [ "$status" -ne 0 ]
}

@test "a partially applied patch is an error rather than a silent skip" {
    # One hunk of a two-hunk patch already present: neither a clean apply nor
    # a clean reverse, which is exactly the state that must not pass quietly.
    printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n' >"$REPO/wide.txt"
    git -C "$REPO" add wide.txt
    git -C "$REPO" commit -qm wide
    printf 'A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n' >"$REPO/wide.txt"
    git -C "$REPO" diff -- wide.txt >"$PATCHES/0003-wide.patch"
    printf 'A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n' >"$REPO/wide.txt"

    run kicad_apply_patches "$PATCHES" "$REPO"
    [ "$status" -ne 0 ]
}

@test "the real patch set applies to a pristine checkout of the pinned revision" {
    # Guards the patches themselves, not the helper: if a manifest revision
    # bump strands one of them, this fails here rather than 40 minutes into a
    # build.
    real="${BATS_TEST_DIRNAME}/../patches/kicad"
    tree="${BATS_TEST_DIRNAME}/../work/kicad"
    [ -d "$tree/.git" ] || skip "work/kicad not checked out"

    for p in "$real"/*.patch; do
        git -C "$tree" apply --check "$p" 2>/dev/null ||
            git -C "$tree" apply --reverse --check "$p" 2>/dev/null ||
            {
                echo "stranded patch: $(basename "$p")"
                false
            }
    done
}
