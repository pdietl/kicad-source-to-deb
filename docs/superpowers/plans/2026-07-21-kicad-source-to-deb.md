# kicad-source-to-deb Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build KiCad 10.0.5-rc1 and its four library repos from source on Ubuntu 26.04 and emit two installable `.deb` packages.

**Architecture:** A `west` manifest pins all five upstream repos by tag. One bash orchestrator configures and builds KiCad with CMake into two `DESTDIR` staging trees, strips debug info, computes dependencies with `dpkg-shlibdeps`, and assembles packages with `dpkg-deb --build`. Pure-logic helpers live in `lib/` and are unit-tested with `bats`.

**Tech Stack:** bash, west (pipx), CMake/Ninja, dpkg-deb, dpkg-shlibdeps, bats, shellcheck, shfmt, lintian.

## Global Constraints

- Target platform is **Ubuntu 26.04 only**. Computed dependencies bind the package to it.
- Install prefix is **`/usr`**. Never `/usr/local` — Debian Policy reserves that for local admin.
- Upstream tag for every repo: **`10.0.5-rc1`**.
- Debian package version: **`10.0.5~rc1-1`**. A literal `-rc1` makes the final release sort as a downgrade.
- Packages produced: **`kicad`** and **`kicad-packages3d`**. No `kicad-dbg`.
- Binaries are **stripped** (`strip --strip-unneeded`). Debug info is 94% of binary size.
- **No substitution variables.** `${binary:Version}` / `${shlibs:Depends}` are expanded by `dpkg-gencontrol`, which is never invoked here. Every control field must be literal.
- CMake flags that do **not exist** in KiCad 10 and must never be passed: `KICAD_USE_OCC`, `KICAD_SPICE`, `KICAD_USE_EGL`, `KICAD_USE_3DCONNEXION`, `KICAD_STOCK_DATA_PATH`.
- Every shell file must pass `shellcheck` and be formatted with `shfmt -i 4 -ci`.
- Repo root for all paths below: `~/Repos/kicad_top/kicad-source-to-deb`.

---

## File Structure

| File | Responsibility |
|---|---|
| `west.yml` | Pins the five upstream repos by tag and clone depth |
| `lib/version.sh` | Derives the Debian version from `git describe` output. Pure. |
| `lib/shlibdeps.sh` | Wraps `dpkg-shlibdeps` with its two workarounds. |
| `lib/stage.sh` | Strips debug info from every ELF in a staging tree. |
| `build-kicad-deb.sh` | Orchestrator. Preflight, sync, configure, build, package. |
| `uninstall-usr-local.sh` | Removes a prior `/usr/local` source install. |
| `packaging/kicad.control.in` | Control template for the main package |
| `packaging/kicad-packages3d.control.in` | Control template for the models package |
| `packaging/kicad.postinst` | Migration warnings (caches are trigger-driven) |
| `packaging/kicad.triggers` | Opts into the named `ldconfig` trigger |
| `tests/*.bats` | Unit tests for `lib/` |
| `README.md` | Usage |

---

### Task 1: Repo scaffolding and west manifest

**Files:**
- Create: `west.yml`, `.gitignore`, `tests/.gitkeep`

**Interfaces:**
- Consumes: nothing
- Produces: a west workspace where `../kicad`, `../kicad-symbols`, `../kicad-footprints`, `../kicad-templates`, `../kicad-packages3D` exist at tag `10.0.5-rc1`.

- [ ] **Step 1: Install the tooling this plan needs**

```bash
sudo apt-get install -y bats lintian
pipx install west
```

- [ ] **Step 2: Verify west is on PATH**

Run: `west --version`
Expected: a version string such as `West version: v1.x.y`. If `command not found`, run `pipx ensurepath` and open a new shell.

- [ ] **Step 3: Write `west.yml`**

```yaml
manifest:
  self:
    path: kicad-source-to-deb

  remotes:
    - name: kicad
      url-base: https://gitlab.com/kicad

  defaults:
    remote: kicad

  projects:
    # Full history deliberately: the build derives its version string from
    # `git describe`, which needs accurate commit counts.
    - name: kicad
      repo-path: code/kicad
      revision: 10.0.5-rc1

    - name: kicad-symbols
      repo-path: libraries/kicad-symbols
      revision: 10.0.5-rc1
      clone-depth: 1

    - name: kicad-footprints
      repo-path: libraries/kicad-footprints
      revision: 10.0.5-rc1
      clone-depth: 1

    - name: kicad-templates
      repo-path: libraries/kicad-templates
      revision: 10.0.5-rc1
      clone-depth: 1

    - name: kicad-packages3D
      repo-path: libraries/kicad-packages3D
      revision: 10.0.5-rc1
      clone-depth: 1
```

- [ ] **Step 4: Write `.gitignore`**

```
build/
stage-*/
*.deb
*.buildinfo
*.changes
```

- [ ] **Step 5: Validate the manifest parses**

Run: `west manifest --validate`
Expected: no output, exit status 0. Any YAML or schema error prints here.

- [ ] **Step 6: Verify the project list resolves to the five expected URLs**

Run: `west list -f '{name} {url} {revision}'`
Expected: five lines, each URL under `https://gitlab.com/kicad/`, each revision `10.0.5-rc1`. Confirm `kicad` maps to `.../code/kicad` and the libraries to `.../libraries/...`.

- [ ] **Step 7: Materialize the workspace**

```bash
cd ..
west init -l kicad-source-to-deb
west update
```

Expected: five sibling directories appear. `kicad-packages3D` is the slow one (~hundreds of MB).

**If `west update` fails to resolve a tag on a shallow clone**, remove the `clone-depth: 1` line from the failing project and re-run. This interaction is untested upstream; the cost of dropping it is clone time, not correctness.

- [ ] **Step 8: Verify checkouts landed on the right tag**

```bash
for d in kicad kicad-symbols kicad-footprints kicad-templates kicad-packages3D; do
    printf '%-20s %s\n' "$d" "$(git -C "$d" describe --tags 2>/dev/null)"
done
```

Expected: every line reports `10.0.5-rc1`.

- [ ] **Step 9: Commit**

```bash
cd kicad-source-to-deb
git add west.yml .gitignore tests/.gitkeep
git commit -m "Add west manifest pinning KiCad 10.0.5-rc1 and library repos"
```

---

### Task 2: Debian version derivation

**Files:**
- Create: `lib/version.sh`, `tests/version.bats`

**Interfaces:**
- Consumes: nothing
- Produces: `kicad_deb_version <git-describe-output>` → echoes a Debian version string. Used by Task 6.

- [ ] **Step 1: Write the failing test**

Create `tests/version.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/version.sh"
}

@test "exact prerelease tag becomes a tilde version with revision 1" {
    run kicad_deb_version "10.0.5-rc1"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.5~rc1-1" ]
}

@test "exact final tag gets revision 1 and no tilde" {
    run kicad_deb_version "10.0.5"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.5-1" ]
}

@test "commits past a prerelease tag are appended with a plus" {
    run kicad_deb_version "10.0.5-rc1-12-gabc1234"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.5~rc1+12.gabc1234-1" ]
}

@test "commits past a final tag are appended with a plus" {
    run kicad_deb_version "10.0.5-12-gabc1234"
    [ "$status" -eq 0 ]
    [ "$output" = "10.0.5+12.gabc1234-1" ]
}

@test "beta and alpha markers are treated as prereleases" {
    run kicad_deb_version "11.0.0-beta2"
    [ "$output" = "11.0.0~beta2-1" ]
    run kicad_deb_version "11.0.0-alpha1"
    [ "$output" = "11.0.0~alpha1-1" ]
}

# The whole point of the tilde. dpkg is the oracle, not our reasoning.
@test "a prerelease sorts BEFORE the final release" {
    rc=$(kicad_deb_version "10.0.5-rc1")
    final=$(kicad_deb_version "10.0.5")
    run dpkg --compare-versions "$rc" lt "$final"
    [ "$status" -eq 0 ]
}

@test "a prerelease sorts AFTER the previous final release" {
    rc=$(kicad_deb_version "10.0.5-rc1")
    prev=$(kicad_deb_version "10.0.4")
    run dpkg --compare-versions "$prev" lt "$rc"
    [ "$status" -eq 0 ]
}

@test "a post-tag snapshot sorts after its own tag" {
    tag=$(kicad_deb_version "10.0.5-rc1")
    snap=$(kicad_deb_version "10.0.5-rc1-12-gabc1234")
    run dpkg --compare-versions "$tag" lt "$snap"
    [ "$status" -eq 0 ]
}

@test "empty input is rejected" {
    run kicad_deb_version ""
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/version.bats`
Expected: every test fails — `lib/version.sh` does not exist, so `load` errors.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/version.sh`:

```bash
#!/usr/bin/env bash
# Derive a Debian package version from `git describe --tags` output.
#
# dpkg reads the last '-' as the separator between upstream version and Debian
# revision, so a literal "10.0.5-rc1" parses as upstream 10.0.5 revision rc1 and
# would sort ABOVE the eventual "10.0.5-1" final release. '~' sorts before
# everything, which is the only construct that orders a prerelease correctly.

kicad_deb_version() {
    local describe=$1
    local base suffix commits sha upstream

    if [ -z "$describe" ]; then
        echo "kicad_deb_version: empty describe output" >&2
        return 1
    fi

    # Split a trailing "-<commits>-g<sha>" produced by git describe past a tag.
    commits=""
    sha=""
    if [[ $describe =~ ^(.+)-([0-9]+)-(g[0-9a-f]+)$ ]]; then
        describe=${BASH_REMATCH[1]}
        commits=${BASH_REMATCH[2]}
        sha=${BASH_REMATCH[3]}
    fi

    # Split a prerelease marker off the tag.
    if [[ $describe =~ ^(.+)-((rc|beta|alpha)[0-9]*)$ ]]; then
        base=${BASH_REMATCH[1]}
        suffix=${BASH_REMATCH[2]}
        upstream="${base}~${suffix}"
    else
        upstream=$describe
    fi

    if [ -n "$commits" ]; then
        upstream="${upstream}+${commits}.${sha}"
    fi

    printf '%s-1\n' "$upstream"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/version.bats`
Expected: `9 tests, 0 failures`.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/version.sh && shfmt -i 4 -ci -d lib/version.sh`
Expected: no output from either.

- [ ] **Step 6: Commit**

```bash
git add lib/version.sh tests/version.bats
git commit -m "Add Debian version derivation with prerelease tilde handling"
```

---

### Task 3: Dependency computation

**Files:**
- Create: `lib/shlibdeps.sh`, `tests/shlibdeps.bats`

**Interfaces:**
- Consumes: nothing
- Produces: `kicad_shlibdeps <stage-dir>` → echoes the value for a `Depends:` field, e.g. `libc6 (>= 2.38), libwxgtk3.2-1t64, ...`. Used by Task 6.

- [ ] **Step 1: Write the failing test**

Create `tests/shlibdeps.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shlibdeps.bats`
Expected: all tests fail — `lib/shlibdeps.sh` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/shlibdeps.sh`:

```bash
#!/usr/bin/env bash
# Compute a Depends: value from the ELF files in a staging tree.
#
# dpkg-shlibdeps has two behaviours that make it awkward outside a Debian source
# package, both confirmed by running it:
#   - it refuses to start without a debian/control file, so one is synthesised;
#   - it treats a library belonging to no package as fatal, which is exactly what
#     KiCad's own libkicommon.so is, so -l points it at the staged lib directory
#     and --ignore-missing-info downgrades the failure.

kicad_shlibdeps() {
    local stage=$1
    local workdir elves out

    if [ ! -d "$stage" ]; then
        echo "kicad_shlibdeps: no such stage directory: $stage" >&2
        return 1
    fi

    mapfile -t elves < <(
        find "$stage" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
            xargs -0 -r file -N |
            awk -F: '/ELF/{print $1}'
    )

    if [ ${#elves[@]} -eq 0 ]; then
        echo "kicad_shlibdeps: no ELF files found under $stage" >&2
        return 1
    fi

    workdir=$(mktemp -d)
    mkdir -p "$workdir/debian"
    printf 'Source: kicad\n\nPackage: kicad\nArchitecture: amd64\n' \
        > "$workdir/debian/control"

    out=$(
        cd "$workdir" &&
            dpkg-shlibdeps -O --ignore-missing-info \
                -l"$stage/usr/lib" \
                -l"$stage/usr/lib/kicad" \
                "${elves[@]}" 2>/dev/null
    )
    rm -rf "$workdir"

    # -O prints "shlibs:Depends=a, b, c"; callers want just the value.
    printf '%s\n' "${out#shlibs:Depends=}"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/shlibdeps.bats`
Expected: `5 tests, 0 failures`.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/shlibdeps.sh && shfmt -i 4 -ci -d lib/shlibdeps.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/shlibdeps.sh tests/shlibdeps.bats
git commit -m "Add dpkg-shlibdeps wrapper handling missing control and private libs"
```

---

### Task 4: Staging and stripping

**Files:**
- Create: `lib/stage.sh`, `tests/stage.bats`

**Interfaces:**
- Consumes: nothing
- Produces: `kicad_strip_tree <dir>` → strips every ELF under `<dir>`, echoes the count stripped.

The two packages are separated by staging them into different `DESTDIR` trees from the start —
`kicad-packages3D`'s CMake installs only `${SHAPE_DIRS}` to the models directory, so nothing has
to be moved afterwards. Task 6 asserts no models leaked into the main tree.

- [ ] **Step 1: Write the failing test**

Create `tests/stage.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load "${BATS_TEST_DIRNAME}/../lib/stage.sh"
    STAGE=$(mktemp -d)
    STAGE3D=$(mktemp -d)
    mkdir -p "$STAGE/usr/bin" "$STAGE/usr/share/kicad/3dmodels/Resistor.3dshapes"
    cp /bin/ls "$STAGE/usr/bin/kicad"
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/stage.bats`
Expected: all fail — `lib/stage.sh` does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/stage.sh`:

```bash
#!/usr/bin/env bash
# Staging-tree helpers: strip debug info, and split the 3D models into their
# own tree so they can ship as a separate package.
#
# Stripping matches upstream: the official AppImage build extracts debug info
# with objcopy --only-keep-debug, indexes it by build-id for debuginfod, then
# runs strip --strip-unneeded over every ELF. Debug info is ~94% of binary size.

kicad_strip_tree() {
    local dir=$1
    local count=0 f

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    while IFS= read -r f; do
        strip --strip-unneeded "$f" 2> /dev/null && count=$((count + 1))
    done < <(
        find "$dir" -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
            xargs -0 -r file -N |
            awk -F: '/ELF.*not stripped/{print $1}'
    )

    printf '%s\n' "$count"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/stage.bats`
Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/stage.sh && shfmt -i 4 -ci -d lib/stage.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/stage.sh tests/stage.bats
git commit -m "Add staging helpers for stripping and 3D model split"
```

---

### Task 5: Packaging templates and maintainer scripts

**Files:**
- Create: `packaging/kicad.control.in`, `packaging/kicad-packages3d.control.in`, `packaging/kicad.postinst`, `packaging/kicad.postrm`, `packaging/kicad-packages3d.postinst`, `packaging/kicad-packages3d.postrm`

**Interfaces:**
- Consumes: nothing
- Produces: templates containing the literal placeholders `@VERSION@`, `@INSTALLED_SIZE@`, `@DEPENDS@`, substituted by Task 6.

- [ ] **Step 1: Write `packaging/kicad.control.in`**

```
Package: kicad
Version: @VERSION@
Section: electronics
Priority: optional
Architecture: amd64
Installed-Size: @INSTALLED_SIZE@
Depends: @DEPENDS@
Recommends: kicad-packages3d
Conflicts: kicad-symbols, kicad-footprints, kicad-templates
Provides: kicad-symbols, kicad-footprints, kicad-templates
Replaces: kicad-symbols, kicad-footprints, kicad-templates
Maintainer: Pete Dietl <petedietl@gmail.com>
Homepage: https://www.kicad.org
Description: Electronic schematic and PCB design software
 KiCad is a cross-platform suite for electronic design automation, covering
 schematic capture, PCB layout, gerber generation and 3D visualisation.
 .
 Built from source at tag 10.0.5-rc1 against this machine's system libraries,
 with symbol, footprint and project-template libraries included. Install
 kicad-packages3d for the 3D component models.
```

- [ ] **Step 2: Write `packaging/kicad-packages3d.control.in`**

```
Package: kicad-packages3d
Version: @VERSION@
Section: electronics
Priority: optional
Architecture: all
Installed-Size: @INSTALLED_SIZE@
Depends: kicad (= @VERSION@)
Maintainer: Pete Dietl <petedietl@gmail.com>
Homepage: https://www.kicad.org
Description: 3D component models for KiCad
 STEP models rendered by KiCad's 3D viewer and emitted by its STEP and VRML
 exporters. KiCad is fully usable without this package: the PCB editor canvas
 is two-dimensional, and the 3D viewer still renders board geometry, just
 without component bodies.
```

- [ ] **Step 3: Write `packaging/kicad.triggers`**

```
activate-noawait ldconfig
```

`libc-bin` declares `ldconfig` as a *named* trigger (`interest-await ldconfig`), so a package
shipping shared libraries opts in rather than calling `ldconfig` itself.

The other three caches need nothing: `desktop-file-utils`, `shared-mime-info` and
`hicolor-icon-theme` declare **path-based** triggers on `/usr/share/applications`,
`/usr/share/mime/packages` and `/usr/share/icons/hicolor` respectively. Installing files into
those paths fires `update-desktop-database`, `update-mime-database` and the icon-cache rebuild
automatically. Calling them from a maintainer script would duplicate work dpkg already does.

- [ ] **Step 4: Write `packaging/kicad.postinst`**

This exists solely for the two migration warnings. Cache refreshes are handled by triggers.

```bash
#!/bin/sh
set -e

# A prior source install under /usr/local shadows this package: /usr/local/bin
# precedes /usr/bin on the default PATH, so the old binary keeps running.
if [ -x /usr/local/bin/kicad ]; then
    echo "WARNING: /usr/local/bin/kicad exists and shadows /usr/bin/kicad." >&2
    echo "         Remove the old source install (uninstall-usr-local.sh)." >&2
fi

# KiCad writes an absolute path into the user's global library table on first
# run and never revisits it. A table pointing outside /usr leaves the library
# list silently empty -- the loader logs a trace and shows no dialog.
for tbl in /home/*/.config/kicad/*/sym-lib-table; do
    [ -f "$tbl" ] || continue
    if grep -q 'uri "/' "$tbl" 2>/dev/null && ! grep -q 'uri "/usr/share/kicad' "$tbl" 2>/dev/null; then
        echo "WARNING: $tbl points outside /usr/share/kicad." >&2
        echo "         Delete sym-lib-table, fp-lib-table and" >&2
        echo "         design-block-lib-table from that profile to re-seed them." >&2
    fi
done

exit 0
```

- [ ] **Step 5: Deliberately ship no `postrm`, and no maintainer scripts for `kicad-packages3d`**

There is no `packaging/kicad.postrm`: the trigger-driven caches clean themselves up on removal,
and the migration warnings are meaningless at that point.

`kicad-packages3d` gets **no maintainer scripts and no triggers**. It ships only data — no
executables, no shared libraries, no desktop files, no icons — so nothing needs to fire. This
matches normal Debian practice: 3,027 of the 3,180 packages installed on this machine carry no
maintainer scripts at all.

Task 6's `build_package()` installs `postinst` and `triggers` **only when the file exists**, so
the absence is handled without placeholder no-op scripts.

- [ ] **Step 6: Lint the maintainer script**

Run: `shellcheck packaging/kicad.postinst`
Expected: no output. It is `/bin/sh`, so shellcheck checks it as POSIX sh.

- [ ] **Step 7: Commit**

```bash
git add packaging/
git commit -m "Add control templates, ldconfig trigger and migration warnings"
```

---

### Task 6: Build orchestrator

**Files:**
- Create: `build-kicad-deb.sh`

**Interfaces:**
- Consumes: `lib/version.sh`, `lib/shlibdeps.sh`, `lib/stage.sh`, `packaging/*`
- Produces: `kicad_<version>_amd64.deb` and `kicad-packages3d_<version>_all.deb` in the invocation directory.

- [ ] **Step 1: Write the script**

Create `build-kicad-deb.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE=$(cd -P "$SCRIPT_DIR/.." && pwd)
ORIG_DIR=$(pwd)

# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/shlibdeps.sh
. "$SCRIPT_DIR/lib/shlibdeps.sh"
# shellcheck source=lib/stage.sh
. "$SCRIPT_DIR/lib/stage.sh"

echo -e "${GREEN}KiCad source-to-deb builder${NC}"
echo "================================"

echo -e "${YELLOW}Checking dependencies...${NC}"
for tool in west cmake ninja g++ dpkg-deb dpkg-shlibdeps git strip file; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo -e "${RED}Error: $tool is not installed${NC}"
        echo "Install build tooling with: sudo apt-get install -y \\"
        echo "    build-essential cmake ninja-build ccache dpkg-dev git binutils"
        echo "and west with: pipx install west"
        exit 1
    fi
done

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "26.04" ]; then
    echo -e "${RED}Error: computed dependencies target Ubuntu 26.04 only" \
        "(detected: ${PRETTY_NAME:-unknown})${NC}"
    exit 1
fi

STAGE_KICAD=$(mktemp -d)
STAGE_3D=$(mktemp -d)
cleanup() { rm -rf "$STAGE_KICAD" "$STAGE_3D"; }
trap cleanup EXIT

echo -e "${YELLOW}Syncing repositories...${NC}"
(cd "$WORKSPACE" && west update)

VERSION=$(kicad_deb_version "$(git -C "$WORKSPACE/kicad" describe --tags)")
echo -e "${GREEN}Package version: $VERSION${NC}"

echo -e "${YELLOW}Configuring...${NC}"
cmake -S "$WORKSPACE/kicad" -B "$WORKSPACE/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DDEFAULT_INSTALL_PATH=/usr \
    -DKICAD_BUILD_I18N=ON \
    -DKICAD_USE_CMAKE_FINDPROTOBUF=ON \
    -DKICAD_BUILD_QA_TESTS=OFF \
    -DKICAD_INSTALL_DEMOS=OFF \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

echo -e "${YELLOW}Building (this takes 30-50 minutes)...${NC}"
cmake --build "$WORKSPACE/build" -j"$(nproc)"

echo -e "${YELLOW}Staging KiCad...${NC}"
DESTDIR=$STAGE_KICAD cmake --install "$WORKSPACE/build"

echo -e "${YELLOW}Staging libraries...${NC}"
# Symbols ship as unpacked .kicad_symdir directories; packing is off to match
# what the official build installs.
cmake -S "$WORKSPACE/kicad-symbols" -B "$WORKSPACE/kicad-symbols/build" -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/usr -DKICAD_PACK_SYM_LIBRARIES=OFF
DESTDIR=$STAGE_KICAD cmake --install "$WORKSPACE/kicad-symbols/build"

for lib in kicad-footprints kicad-templates; do
    cmake -S "$WORKSPACE/$lib" -B "$WORKSPACE/$lib/build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr
    DESTDIR=$STAGE_KICAD cmake --install "$WORKSPACE/$lib/build"
done

# The models go straight into their own tree: this repo's CMake installs only
# the shape directories, so no post-hoc move is needed.
echo -e "${YELLOW}Staging 3D models...${NC}"
cmake -S "$WORKSPACE/kicad-packages3D" -B "$WORKSPACE/kicad-packages3D/build" \
    -G Ninja -DCMAKE_INSTALL_PREFIX=/usr
DESTDIR=$STAGE_3D cmake --install "$WORKSPACE/kicad-packages3D/build"

if [ -e "$STAGE_KICAD/usr/share/kicad/3dmodels" ]; then
    echo -e "${RED}Error: 3D models leaked into the main package tree${NC}"
    exit 1
fi

echo -e "${YELLOW}Stripping debug info...${NC}"
stripped=$(kicad_strip_tree "$STAGE_KICAD")
echo "  stripped $stripped ELF files"

echo -e "${YELLOW}Computing dependencies...${NC}"
DEPENDS=$(kicad_shlibdeps "$STAGE_KICAD")

build_package() {
    local name=$1 stage=$2 arch=$3
    local size pkgdir

    size=$(du -sk "$stage/usr" | cut -f1)
    pkgdir="$stage/DEBIAN"
    mkdir -p "$pkgdir"

    sed -e "s|@VERSION@|$VERSION|g" \
        -e "s|@INSTALLED_SIZE@|$size|g" \
        -e "s|@DEPENDS@|$DEPENDS|g" \
        "$SCRIPT_DIR/packaging/$name.control.in" > "$pkgdir/control"

    # Only the kicad package has these; the models package is pure data and
    # correctly ships none.
    [ -f "$SCRIPT_DIR/packaging/$name.postinst" ] &&
        install -m 0755 "$SCRIPT_DIR/packaging/$name.postinst" "$pkgdir/postinst"
    [ -f "$SCRIPT_DIR/packaging/$name.triggers" ] &&
        install -m 0644 "$SCRIPT_DIR/packaging/$name.triggers" "$pkgdir/triggers"

    fakeroot dpkg-deb --build "$stage" \
        "$ORIG_DIR/${name}_${VERSION}_${arch}.deb"
}

echo -e "${YELLOW}Building packages...${NC}"
build_package kicad "$STAGE_KICAD" amd64
build_package kicad-packages3d "$STAGE_3D" all

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Success!${NC}"
ls -lh "$ORIG_DIR"/kicad*_"${VERSION}"_*.deb
echo ""
echo "To install:"
echo "  sudo apt install $ORIG_DIR/kicad_${VERSION}_amd64.deb \\"
echo "                   $ORIG_DIR/kicad-packages3d_${VERSION}_all.deb"
```

- [ ] **Step 2: Lint**

Run: `shellcheck build-kicad-deb.sh && shfmt -i 4 -ci -d build-kicad-deb.sh`
Expected: no output.

- [ ] **Step 3: Run the full build**

Run: `./build-kicad-deb.sh`
Expected: 30–50 minutes, ending with two `.deb` paths listed.

- [ ] **Step 4: Verify package metadata**

```bash
dpkg-deb --info kicad_10.0.5~rc1-1_amd64.deb
dpkg-deb --info kicad-packages3d_10.0.5~rc1-1_all.deb
```

Expected: `Version: 10.0.5~rc1-1` on both; `Depends:` on the first is a populated comma-separated list containing `libc6`; the second depends on `kicad (= 10.0.5~rc1-1)`. No `@VERSION@` or `${...}` remains anywhere.

- [ ] **Step 5: Verify the model split actually happened**

```bash
dpkg-deb -c kicad_10.0.5~rc1-1_amd64.deb | grep -c 3dmodels || echo 0
dpkg-deb -c kicad-packages3d_10.0.5~rc1-1_all.deb | grep -c 3dmodels
```

Expected: `0` for the first, a large number for the second.

- [ ] **Step 6: Verify demos were excluded and binaries stripped**

```bash
dpkg-deb -c kicad_10.0.5~rc1-1_amd64.deb | grep -c 'share/kicad/demos' || echo 0
dpkg-deb -x kicad_10.0.5~rc1-1_amd64.deb /tmp/kicadpkg
file /tmp/kicadpkg/usr/bin/kicad
rm -rf /tmp/kicadpkg
```

Expected: `0` demos; `file` reports `stripped`.

- [ ] **Step 7: Run lintian**

Run: `lintian kicad_10.0.5~rc1-1_amd64.deb || true`
Expected: warnings are acceptable for a hand-rolled package. Read the output and confirm none are errors about a malformed `control` file, a bad version, or missing `Depends`.

- [ ] **Step 8: Commit**

```bash
git add build-kicad-deb.sh
git commit -m "Add build orchestrator producing both deb packages"
```

---

### Task 7: Migration script and README

**Files:**
- Create: `uninstall-usr-local.sh`, `README.md`

**Interfaces:**
- Consumes: nothing
- Produces: `uninstall-usr-local.sh`, invoked by `provision` in Task 8.

- [ ] **Step 1: Write `uninstall-usr-local.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Remove a prior KiCad installed from source under /usr/local.
#
# /usr/local/bin precedes /usr/bin on the default PATH, so an old source install
# shadows the packaged one: apt reports success and the stale binary keeps
# running. This is deliberately NOT done from a maintainer script -- Debian
# Policy reserves /usr/local for the local administrator.

MANIFEST=${1:-}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    echo "Removing files listed in $MANIFEST"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
        /usr/local/*) rm -f "$f" ;;
        *) echo "  skipping out-of-prefix path: $f" >&2 ;;
        esac
    done < "$MANIFEST"
else
    echo "No install manifest given; removing known /usr/local KiCad paths"
    rm -rf /usr/local/share/kicad
    rm -rf /usr/local/lib/kicad
    rm -f /usr/local/lib/libkicommon.so*
    rm -f /usr/local/bin/kicad /usr/local/bin/kicad-cli /usr/local/bin/eeschema \
        /usr/local/bin/pcbnew /usr/local/bin/gerbview /usr/local/bin/pl_editor \
        /usr/local/bin/pcb_calculator /usr/local/bin/bitmap2component
fi

# Prune now-empty directories without disturbing anything else under /usr/local.
rmdir --ignore-fail-on-non-empty /usr/local/share/kicad 2> /dev/null || true

ldconfig
echo "Done. /usr/local KiCad removed."
```

- [ ] **Step 2: Lint**

Run: `shellcheck uninstall-usr-local.sh && shfmt -i 4 -ci -d uninstall-usr-local.sh`
Expected: no output.

- [ ] **Step 3: Write `README.md`**

```markdown
# kicad-source-to-deb

Builds KiCad from source on Ubuntu 26.04 and packages it as two `.deb` files.

Companion to [saleae-logic2-appimage-to-deb](https://github.com/pdietl/saleae-logic2-appimage-to-deb).

## What you get

| Package | Installed | Contents |
|---|---|---|
| `kicad` | ~271 MB | binaries, symbols, footprints, templates, i18n, desktop integration |
| `kicad-packages3d` | ~1.2 GB | STEP models for the 3D viewer and STEP/VRML export |

`kicad-packages3d` is optional. The PCB editor canvas is 2D; without the models
the 3D viewer still renders board geometry, just no component bodies.

## Usage

    sudo apt-get install -y build-essential cmake ninja-build ccache dpkg-dev \
        git binutils bats lintian
    pipx install west

    git clone https://github.com/pdietl/kicad-source-to-deb.git
    west init -l kicad-source-to-deb
    west update

    cd kicad-source-to-deb
    ./build-kicad-deb.sh

The build takes 30-50 minutes and needs roughly 25 GB of scratch space.

    sudo apt install ./kicad_*.deb ./kicad-packages3d_*.deb

## Upgrading to a new KiCad release

Edit the five `revision:` values in `west.yml`, then `west update` and rebuild.

## Migrating from a /usr/local source install

`/usr/local/bin` precedes `/usr/bin` on PATH, so an old source install shadows
the package:

    sudo ./uninstall-usr-local.sh /path/to/build/install_manifest.txt

KiCad also writes an absolute path into the per-user library table on first run
and never revisits it, so a prefix change leaves the library list silently
empty. Reset it:

    rm ~/.config/kicad/10.0/{sym,fp,design-block}-lib-table

They are re-seeded against the new prefix on next launch.

## Tests

    bats tests/
    shellcheck *.sh lib/*.sh packaging/*.postinst packaging/*.postrm
```

- [ ] **Step 4: Verify the tests referenced in the README actually pass**

Run: `bats tests/`
Expected: `17 tests, 0 failures` across the three test files (9 version, 5 shlibdeps, 3 stage).

- [ ] **Step 5: Commit**

```bash
git add uninstall-usr-local.sh README.md
git commit -m "Add /usr/local migration script and README"
```

---

### Task 8: provision integration

**Files:**
- Modify: `/home/pdietl/Repos/dev_tools/provision` — insert after the Saleae Logic2 block (currently ends at line 341)

**Interfaces:**
- Consumes: `build-kicad-deb.sh`, `uninstall-usr-local.sh`
- Produces: nothing downstream

- [ ] **Step 1: Add the KiCad block to `provision`**

Insert immediately after the Saleae Logic2 block:

```bash
if in_wsl; then
    echo "  KiCad: skipped (WSL)"
elif dpkg-query -Wf'${db:Status-abbrev}' kicad 2> /dev/null | grep -q '^i'; then
    echo "  KiCad: already installed"
else
    echo "  KiCad: building from source (30-50 min)..."
    sudo -u "$SUDO_USER" -- pipx install west > /dev/null 2>&1 || true
    kicad_ws=$USER_HOME/Repos/kicad_top
    installUser "$kicad_ws"
    sudo -H -u "$SUDO_USER" bash -ec "
        cd '$kicad_ws'
        [ -d kicad-source-to-deb ] ||
            git clone https://github.com/pdietl/kicad-source-to-deb.git
        west init -l kicad-source-to-deb 2>/dev/null || true
        west update
        cd kicad-source-to-deb
        ./build-kicad-deb.sh
    "
    kicad_debs=$(ls -1 "$kicad_ws"/kicad-source-to-deb/kicad*_*.deb 2> /dev/null || true)
    if [ -z "$kicad_debs" ]; then
        echo "Error: KiCad deb files not found!"
        exit 1
    fi
    # shellcheck disable=SC2086
    _apt_get install -y $kicad_debs
    rm -f $kicad_debs

    # A prior /usr/local source install shadows /usr/bin on PATH.
    if [ -x /usr/local/bin/kicad ]; then
        "$kicad_ws"/kicad-source-to-deb/uninstall-usr-local.sh \
            "$kicad_ws"/build/install_manifest.txt
    fi

    # KiCad pins an absolute prefix into the per-user library table on first
    # run and never revisits it; a stale table yields an empty library list
    # with no error shown.
    for tbl in "$USER_HOME"/.config/kicad/*/; do
        [ -d "$tbl" ] || continue
        rm -f "$tbl"/sym-lib-table "$tbl"/fp-lib-table "$tbl"/design-block-lib-table
    done
fi
```

- [ ] **Step 2: Lint the modified provision script**

Run: `shellcheck /home/pdietl/Repos/dev_tools/provision`
Expected: no new findings beyond those already present before the edit. Compare against `git stash`-ed output if unsure.

- [ ] **Step 3: Verify the block is idempotent without running a build**

```bash
dpkg-query -Wf'${db:Status-abbrev}' kicad 2>/dev/null | grep -q '^i' && echo "would skip" || echo "would build"
```

Expected: `would skip` on a machine with the package installed — proving the guard short-circuits before the 45-minute build.

- [ ] **Step 4: Commit**

```bash
cd /home/pdietl/Repos/dev_tools
git add provision
git commit -m "Install KiCad from the source-to-deb builder"
```

---

## Verification

After `sudo apt install` of both packages, on a profile with the lib tables reset:

| Check | Expected |
|---|---|
| `which kicad` | `/usr/bin/kicad` |
| `kicad-cli version` | `10.0.5` |
| `python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"` | `10.0.5-rc1` |
| `dpkg -l kicad kicad-packages3d` | both `ii`, version `10.0.5~rc1-1` |
| `grep -o 'uri "[^"]*"' ~/.config/kicad/10.0/sym-lib-table` | a path under `/usr/share/kicad` |
| `gtk-launch org.kicad.kicad` | launches |
| Preferences → Manage Symbol Libraries | populated |
| View → 3D Viewer on a board | component bodies render |
