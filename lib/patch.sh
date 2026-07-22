#!/usr/bin/env bash
# Apply this repo's local patches to a west-managed source checkout.
#
# `west update` detaches each project to the manifest revision but carries
# uncommitted working-tree changes forward rather than discarding them, so a
# second run of the build script meets an already-patched tree. Resetting the
# checkout first would make the step idempotent, but it would also throw away
# whatever else is uncommitted there -- these are ordinary source trees that
# someone may well be editing. So nothing is ever reset: each patch is
# classified against the tree and only applied when it is actually missing.
#
# The three outcomes are deliberately distinguished, because "already applied"
# and "does not fit this tree" look identical to a bare `git apply` -- both
# just fail. Treating the pair as one skippable case is what lets a patch
# silently stop being applied after an upstream version bump, quietly
# reintroducing whatever it fixed.

# kicad_apply_patches <patch-dir> <repo>
# Applies every *.patch in <patch-dir> to the git checkout <repo>, in sorted
# order (patches are numbered and may build on each other). Prints a one-line
# summary per patch. Returns 1 if any patch neither applies nor is already
# applied, if either directory is missing, or if <patch-dir> holds no patches
# at all -- a patch set that silently shrank to nothing still builds, and ships
# every defect the patches existed to fix.
kicad_apply_patches() {
    local patch_dir=$1 repo=$2
    local p name applied=0 already=0
    local patches=()

    if [ ! -d "$patch_dir" ]; then
        echo "kicad_apply_patches: no such patch directory: $patch_dir" >&2
        return 1
    fi
    if [ ! -d "$repo/.git" ]; then
        echo "kicad_apply_patches: not a git checkout: $repo" >&2
        return 1
    fi

    # Absolute, because `git -C "$repo"` resolves a relative patch path
    # against the repo rather than the caller's directory. LC_ALL=C so the
    # numeric prefixes order identically regardless of the invoking locale.
    patch_dir=$(cd -P "$patch_dir" && pwd)
    while IFS= read -r p; do
        patches+=("$p")
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)

    if [ "${#patches[@]}" -eq 0 ]; then
        echo "kicad_apply_patches: no *.patch files in $patch_dir" >&2
        return 1
    fi

    for p in "${patches[@]}"; do
        name=$(basename "$p")
        if git -C "$repo" apply --check "$p" 2>/dev/null; then
            if ! git -C "$repo" apply "$p"; then
                echo "kicad_apply_patches: $name passed --check but failed to apply" >&2
                return 1
            fi
            echo "  applied  $name"
            applied=$((applied + 1))
        elif git -C "$repo" apply --reverse --check "$p" 2>/dev/null; then
            echo "  present  $name"
            already=$((already + 1))
        else
            echo "kicad_apply_patches: $name does not apply to $repo and is not" \
                "already applied -- it likely needs rebasing onto the current" \
                "upstream revision" >&2
            return 1
        fi
    done

    echo "  ${applied} applied, ${already} already present"
}
