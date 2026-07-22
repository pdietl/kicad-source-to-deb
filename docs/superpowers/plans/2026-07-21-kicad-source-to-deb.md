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
| `lib/elf.sh` | Enumerates ELF files under a tree by `file`-based type, not name or permission bits. Shared by `lib/shlibdeps.sh` and `lib/stage.sh`. |
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

@test "a bare two-component version is accepted" {
    run kicad_deb_version "11.0"
    [ "$status" -eq 0 ]
    [ "$output" = "11.0-1" ]
}

@test "an uppercase prerelease marker is rejected" {
    run kicad_deb_version "10.0.5-RC1"
    [ "$status" -ne 0 ]
}

@test "an unrecognized suffix is rejected" {
    run kicad_deb_version "10.0.5-banana7"
    [ "$status" -ne 0 ]
}

@test "whitespace-only input is rejected" {
    run kicad_deb_version " "
    [ "$status" -ne 0 ]
}

@test "a call with no argument is rejected cleanly rather than crashing" {
    run kicad_deb_version
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
    local describe=${1:-}
    local base suffix commits sha upstream
    # Anchored end to end: dotted numeric version, optional lowercase
    # prerelease marker, optional git-describe "-<commits>-g<sha>" tail.
    # Anything that doesn't fully match is refused rather than passed
    # through — an unrecognised format could still print a version string,
    # but one whose ordering guarantee we can no longer vouch for.
    local pattern='^([0-9]+(\.[0-9]+)*)(-((rc|beta|alpha)[0-9]+))?(-([0-9]+)-(g[0-9a-f]+))?$'

    if [ -z "$describe" ]; then
        echo "kicad_deb_version: empty describe output" >&2
        return 1
    fi

    if ! [[ $describe =~ $pattern ]]; then
        echo "kicad_deb_version: unrecognized describe format: $describe" >&2
        return 1
    fi

    base=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[4]}
    commits=${BASH_REMATCH[7]}
    sha=${BASH_REMATCH[8]}

    if [ -n "$suffix" ]; then
        upstream="${base}~${suffix}"
    else
        upstream=$base
    fi

    if [ -n "$commits" ]; then
        upstream="${upstream}+${commits}.${sha}"
    fi

    printf '%s-1\n' "$upstream"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/version.bats`
Expected: `14 tests, 0 failures`.

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
- Create: `lib/elf.sh`, `lib/shlibdeps.sh`, `tests/shlibdeps.bats`

**Interfaces:**
- Consumes: nothing
- Produces: `kicad_find_elf <dir> <desc-glob>` → prints NUL-terminated paths of every regular file under `<dir>` whose `file` description matches the glob (e.g. `'*ELF*'`). Shared with Task 4, which reuses it rather than re-deriving its own `find`/`file` predicate.
- Produces: `kicad_shlibdeps <stage-dir>` → echoes the value for a `Depends:` field, e.g. `libc6 (>= 2.38), libwxgtk3.2-1t64, ...`. Used by Task 6.

- [ ] **Step 1: Write the failing test**

Create `tests/shlibdeps.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/shlibdeps.bats`
Expected: all tests fail — `lib/elf.sh` and `lib/shlibdeps.sh` do not exist.

- [ ] **Step 3: Write the shared ELF-discovery helper**

Create `lib/elf.sh`:

```bash
#!/usr/bin/env bash
# Enumerate ELF files under a directory tree by asking `file` what each
# regular file actually is, not by guessing from its name or permission
# bits. KiCad's kiface plugin modules (_pcbnew.kiface, _eeschema.kiface,
# _cvpcb.kiface, _gerbview.kiface, _kipython.kiface, _pcb_calculator.kiface,
# _pl_editor.kiface) install mode 0644 with no ".so" in the name and carry
# the bulk of KiCad's code, so a permission- or name-based filter
# (`-perm -u+x -o -name '*.so*'`) misses every one of them -- both when
# stripping debug info and when computing shared-library dependencies, so
# both callers share this scan rather than each re-deriving their own
# `find`/`file` predicate that could drift out of agreement.
#
# `file -N -0` NUL-terminates each filename before its description; a plain
# `awk -F:` split instead truncates any path containing a colon at the first
# colon, handing the caller a bogus, nonexistent path.

# kicad_find_elf <dir> <desc-glob>
# Prints NUL-terminated paths of every regular file under <dir> whose `file`
# description matches the glob <desc-glob> (e.g. '*ELF*', or
# '*ELF*not stripped*' to select only unstripped ELF files).
kicad_find_elf() {
    local dir=$1 pattern=$2
    local f desc

    while IFS= read -r -d '' f; do
        IFS= read -r desc
        # shellcheck disable=SC2254 # unquoted on purpose: caller-supplied glob
        case "$desc" in
            $pattern)
                printf '%s\0' "$f"
                ;;
        esac
    done < <(
        find "$dir" -type f -print0 |
            xargs -0 -r file -N -0
    )
}
```

- [ ] **Step 4: Write the minimal implementation**

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
#     and --ignore-missing-info downgrades the failure. KiCad also installs its
#     kiface plugin modules a directory deeper, under usr/lib/kicad, so that path
#     is added too -- without it those modules' own NEEDED libs go unresolved.
#
# ELF discovery is shared with lib/stage.sh -- see lib/elf.sh. Every regular
# file is tested, not just executable ones or ones named *.so*: those kiface
# modules install mode 0644 with no ".so" in the name, so a permission- or
# name-based filter never sees them, and their own NEEDED libraries never
# reach dpkg-shlibdeps.

kicad_shlibdeps() {
    local stage=$1
    local workdir out err rc f
    local elves=()

    if [ ! -d "$stage" ]; then
        echo "kicad_shlibdeps: no such stage directory: $stage" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        elves+=("$f")
    done < <(kicad_find_elf "$stage" '*ELF*')

    if [ ${#elves[@]} -eq 0 ]; then
        echo "kicad_shlibdeps: no ELF files found under $stage" >&2
        return 1
    fi

    workdir=$(mktemp -d)
    mkdir -p "$workdir/debian"
    printf 'Source: kicad\n\nPackage: kicad\nArchitecture: amd64\n' \
        >"$workdir/debian/control"

    err=$(mktemp)
    out=$(
        cd "$workdir" &&
            dpkg-shlibdeps -O --ignore-missing-info \
                -l"$stage/usr/lib" \
                -l"$stage/usr/lib/kicad" \
                "${elves[@]}" 2>"$err"
    )
    rc=$?
    rm -rf "$workdir"

    if [ "$rc" -ne 0 ]; then
        echo "kicad_shlibdeps: dpkg-shlibdeps failed for $stage:" >&2
        cat "$err" >&2
        rm -f "$err"
        return 1
    fi
    rm -f "$err"

    # -O prints "shlibs:Depends=a, b, c"; callers want just the value.
    out=${out#shlibs:Depends=}

    if [ -z "$out" ]; then
        echo "kicad_shlibdeps: dpkg-shlibdeps produced no dependencies for $stage" >&2
        return 1
    fi

    printf '%s\n' "$out"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats tests/shlibdeps.bats`
Expected: `8 tests, 0 failures`.

- [ ] **Step 6: Lint**

Run: `shellcheck lib/elf.sh lib/shlibdeps.sh && shfmt -i 4 -ci -d lib/elf.sh lib/shlibdeps.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add lib/elf.sh lib/shlibdeps.sh tests/shlibdeps.bats
git commit -m "Add dpkg-shlibdeps wrapper handling missing control and private libs"
```

---

### Task 4: Staging and stripping

**Files:**
- Create: `lib/stage.sh`, `tests/stage.bats`

**Interfaces:**
- Consumes: `lib/elf.sh` (`kicad_find_elf`), created in Task 3. Not recreated here.
- Produces: `kicad_strip_tree <dir>` → strips every ELF under `<dir>`, echoes the count stripped,
  and returns non-zero if `strip` failed on any file (all matching files are still attempted).

The two packages are separated by staging them into different `DESTDIR` trees from the start —
`kicad-packages3D`'s CMake installs only `${SHAPE_DIRS}` to the models directory, so nothing has
to be moved afterwards. Task 6 asserts no models leaked into the main tree.

- [ ] **Step 1: Write the failing test**

Create `tests/stage.bats`:

```bash
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
#
# ELF discovery is shared with lib/shlibdeps.sh -- see lib/elf.sh.

kicad_strip_tree() {
    local dir=$1
    local count=0 failed=0 f

    if [ ! -d "$dir" ]; then
        echo "kicad_strip_tree: no such directory: $dir" >&2
        return 1
    fi

    while IFS= read -r -d '' f; do
        if strip --strip-unneeded "$f"; then
            count=$((count + 1))
        else
            echo "kicad_strip_tree: strip failed on: $f" >&2
            failed=1
        fi
    done < <(kicad_find_elf "$dir" '*ELF*not stripped*')

    printf '%s\n' "$count"

    [ "$failed" -eq 0 ]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/stage.bats`
Expected: `6 tests, 0 failures`.

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
- Create: `packaging/kicad.control.in`, `packaging/kicad-packages3d.control.in`, `packaging/kicad.postinst`, `packaging/kicad.triggers`

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
- Consumes: `lib/version.sh`, `lib/elf.sh`, `lib/shlibdeps.sh`, `lib/stage.sh`, `packaging/*`
- Produces: `kicad_<version>_amd64.deb` and `kicad-packages3d_<version>_all.deb` in the invocation directory.

- [ ] **Step 1: Write the script**

Create `build-kicad-deb.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE=$(cd -P "$SCRIPT_DIR/.." && pwd)
ORIG_DIR=$(pwd)

# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/elf.sh
. "$SCRIPT_DIR/lib/elf.sh"
# shellcheck source=lib/shlibdeps.sh
. "$SCRIPT_DIR/lib/shlibdeps.sh"
# shellcheck source=lib/stage.sh
. "$SCRIPT_DIR/lib/stage.sh"

echo -e "${GREEN}KiCad source-to-deb builder${NC}"
echo "================================"

echo -e "${YELLOW}Checking dependencies...${NC}"
for tool in west cmake ninja g++ dpkg-deb dpkg-shlibdeps git strip file; do
    if ! command -v "$tool" >/dev/null 2>&1; then
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

# Library repos are west-managed source checkouts, not build areas: configuring
# a build/ directory inside one leaves it with untracked cruft `git status`
# reports, and any state a prior run left behind there can break a later run
# in a way whose error points at the source checkout instead of the real
# cause. Give the script a build area of its own, outside every checkout.
LIB_BUILD_ROOT="$WORKSPACE/.build"
mkdir -p "$LIB_BUILD_ROOT"

# /tmp on this machine is tmpfs (RAM-backed). Staging holds the full KiCad
# install plus several GB of 3D models, and dpkg-deb needs scratch space
# again on top of that while assembling control.tar/data.tar -- both stages
# honor TMPDIR (mktemp(1), dpkg-deb(1)). Point everything at disk instead,
# next to the library build dirs.
export TMPDIR="$LIB_BUILD_ROOT"
STAGE_KICAD=$(mktemp -d -p "$LIB_BUILD_ROOT" stage-kicad-XXXXXX)
STAGE_3D=$(mktemp -d -p "$LIB_BUILD_ROOT" stage-3d-XXXXXX)

CURRENT_STAGE="initializing"
stage() {
    CURRENT_STAGE=$1
    echo -e "${YELLOW}${1}...${NC}"
}

# `set -e` routes a failing command here first, while $CURRENT_STAGE and
# $LINENO still identify what broke; the EXIT trap below then decides what to
# do with the staging trees based on the exit status this leaves behind.
on_error() {
    local line=$1
    echo -e "${RED}Error: build failed during '${CURRENT_STAGE}' (line ${line})${NC}" >&2
}
trap 'on_error $LINENO' ERR

# Runs on every exit, success or failure. A failure must not delete the
# staging trees -- they are the only evidence of what the failed stage
# produced -- so capture the real exit status before any command in this
# function (even echo) can overwrite it, and only clean up once that status
# is confirmed to be success.
cleanup() {
    local exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        rm -rf "$STAGE_KICAD" "$STAGE_3D"
    else
        echo -e "${YELLOW}Staging directories preserved for inspection:${NC}" >&2
        echo "  kicad:            $STAGE_KICAD" >&2
        echo "  kicad-packages3d: $STAGE_3D" >&2
    fi
    exit "$exit_code"
}
trap cleanup EXIT

stage "Syncing repositories"
(cd "$WORKSPACE" && west update)

VERSION=$(kicad_deb_version "$(git -C "$WORKSPACE/kicad" describe --tags)")
echo -e "${GREEN}Package version: $VERSION${NC}"

stage "Configuring KiCad"
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

stage "Building KiCad (this takes 30-50 minutes)"
cmake --build "$WORKSPACE/build" -j"$(nproc)"

stage "Staging KiCad"
DESTDIR=$STAGE_KICAD cmake --install "$WORKSPACE/build"

# Symbols ship as unpacked .kicad_symdir directories; packing is off to match
# what the official build installs.
stage "Staging kicad-symbols"
cmake -S "$WORKSPACE/kicad-symbols" -B "$LIB_BUILD_ROOT/kicad-symbols" -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/usr -DKICAD_PACK_SYM_LIBRARIES=OFF
DESTDIR=$STAGE_KICAD cmake --install "$LIB_BUILD_ROOT/kicad-symbols"

for lib in kicad-footprints kicad-templates; do
    stage "Staging $lib"
    cmake -S "$WORKSPACE/$lib" -B "$LIB_BUILD_ROOT/$lib" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr
    DESTDIR=$STAGE_KICAD cmake --install "$LIB_BUILD_ROOT/$lib"
done

# The models go straight into their own tree: this repo's CMake installs only
# the shape directories, so no post-hoc move is needed.
stage "Staging 3D models"
cmake -S "$WORKSPACE/kicad-packages3D" -B "$LIB_BUILD_ROOT/kicad-packages3D" \
    -G Ninja -DCMAKE_INSTALL_PREFIX=/usr
DESTDIR=$STAGE_3D cmake --install "$LIB_BUILD_ROOT/kicad-packages3D"

if [ -e "$STAGE_KICAD/usr/share/kicad/3dmodels" ]; then
    echo -e "${RED}Error: 3D models leaked into the main package tree${NC}"
    exit 1
fi

stage "Stripping debug info"
stripped=$(kicad_strip_tree "$STAGE_KICAD")
echo "  stripped $stripped ELF files"

stage "Computing dependencies"
DEPENDS=$(kicad_shlibdeps "$STAGE_KICAD")

build_package() {
    local name=$1 pkg_stage=$2 arch=$3
    local size pkgdir control

    size=$(du -sk "$pkg_stage/usr" | cut -f1)
    pkgdir="$pkg_stage/DEBIAN"
    mkdir -p "$pkgdir"

    # Native substitution, not sed: dpkg-shlibdeps legitimately emits `|` for
    # alternative dependencies (e.g. "libglu1-mesa | libglu1"), which collides
    # with a `|`-delimited sed s/// the moment such a package appears in
    # $DEPENDS. Bash's ${var//pat/repl} has no delimiter to collide with.
    control=$(<"$SCRIPT_DIR/packaging/$name.control.in")
    control=${control//@VERSION@/$VERSION}
    control=${control//@INSTALLED_SIZE@/$size}
    control=${control//@DEPENDS@/$DEPENDS}
    printf '%s\n' "$control" >"$pkgdir/control"

    # Only the kicad package has these; the models package is pure data and
    # correctly ships none.
    [ -f "$SCRIPT_DIR/packaging/$name.postinst" ] &&
        install -m 0755 "$SCRIPT_DIR/packaging/$name.postinst" "$pkgdir/postinst"
    [ -f "$SCRIPT_DIR/packaging/$name.triggers" ] &&
        install -m 0644 "$SCRIPT_DIR/packaging/$name.triggers" "$pkgdir/triggers"

    fakeroot dpkg-deb --build "$pkg_stage" \
        "$ORIG_DIR/${name}_${VERSION}_${arch}.deb"
}

stage "Building packages"
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
- Create: `uninstall-usr-local.sh`, `lib/uninstall.sh`, `tests/uninstall.bats`, `README.md`

**Interfaces:**
- Consumes: `lib/uninstall.sh` (`kicad_uninstall_resolve_under_prefix`,
  `kicad_uninstall_remove_desktop_integration`)
- Produces: `uninstall-usr-local.sh`, invoked by `provision` in Task 8.

- [ ] **Step 1: Write `lib/uninstall.sh`**

A manifest is untrusted input processed as root, so the path-containment
decision is a pure function, factored out so it can be unit-tested against a
fake tree instead of only ever being exercised by `rm -f` on the real
filesystem. A raw `case "$f" in /usr/local/*)` text match is defeated by a
`..` traversal or a symlinked intermediate component; resolving the path
first with `realpath -m` (which tolerates a target that no longer exists --
a manifest may list files a previous run already removed) and testing
containment on the *resolved* form closes both.

```bash
#!/usr/bin/env bash
# Decide whether a raw manifest line refers to a path actually contained in a
# prefix, before uninstall-usr-local.sh acts on it as root.
#
# A textual prefix check (`case "$f" in "$prefix"/*)`) is defeated two ways:
# a ".." traversal embedded in the manifest line (e.g.
# "$prefix/../../etc/passwd" textually starts with "$prefix/" but resolves
# elsewhere), and a symlinked intermediate path component. Both are defeated
# by resolving the path first and testing containment on the resolved form,
# not the raw text.
#
# realpath -m tolerates a target that doesn't exist, which matters here: a
# manifest may list files a previous run already removed.

# kicad_uninstall_resolve_under_prefix <raw-path> <prefix>
# On success, prints the canonical form of <raw-path> and returns 0. Returns
# 1 for a blank input or a path whose canonical form is not <prefix> itself
# or something under it.
kicad_uninstall_resolve_under_prefix() {
    local raw=$1 prefix=$2 resolved

    [ -n "$raw" ] || return 1

    resolved=$(realpath -m -- "$raw") || return 1

    case "$resolved" in
        "$prefix" | "$prefix"/*)
            printf '%s\n' "$resolved"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# kicad_uninstall_remove_desktop_integration <prefix>
#
# PATH shadowing isn't the only way a source install under <prefix> outlives
# its uninstall: XDG_DATA_DIRS puts "$prefix/share" ahead of "/usr/share"
# (e.g. "/usr/local/share/:/usr/share/:..."), so a stale desktop entry, icon
# or MIME definition left under <prefix> keeps winning over the one the .deb
# installs, even after the executables are gone -- the desktop environment
# still shows an entry whose Exec=kicad now resolves through PATH to nothing.
#
# "$prefix/share/applications", ".../icons/hicolor", ".../mime/packages" and
# the completion directories are shared with other locally-installed
# software, so only the exact files KiCad's own install places there are
# removed here, by name; the containing directories are never touched.
# "$prefix/share/kicad" is KiCad-exclusive and is removed wholesale by the
# caller instead.
kicad_uninstall_remove_desktop_integration() {
    local prefix=$1 size scalable mimetype

    rm -f "$prefix"/share/applications/org.kicad.kicad.desktop \
        "$prefix"/share/applications/org.kicad.eeschema.desktop \
        "$prefix"/share/applications/org.kicad.gerbview.desktop \
        "$prefix"/share/applications/org.kicad.pcbnew.desktop \
        "$prefix"/share/applications/org.kicad.pcbcalculator.desktop \
        "$prefix"/share/applications/org.kicad.bitmap2component.desktop

    for size in 16x16 24x24 32x32 48x48 64x64 128x128; do
        [ -d "$prefix/share/icons/hicolor/$size" ] || continue
        rm -f "$prefix/share/icons/hicolor/$size"/apps/kicad.png \
            "$prefix/share/icons/hicolor/$size"/apps/eeschema.png \
            "$prefix/share/icons/hicolor/$size"/apps/gerbview.png \
            "$prefix/share/icons/hicolor/$size"/apps/pcbnew.png \
            "$prefix/share/icons/hicolor/$size"/apps/pcbcalculator.png \
            "$prefix/share/icons/hicolor/$size"/apps/bitmap2component.png
        rm -f "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-footprint.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-pcb.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-project.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-schematic.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-symbol.png \
            "$prefix/share/icons/hicolor/$size"/mimetypes/application-x-kicad-worksheet.png
    done

    scalable="$prefix/share/icons/hicolor/scalable"
    if [ -d "$scalable" ]; then
        rm -f "$scalable"/apps/kicad.svg "$scalable"/apps/eeschema.svg \
            "$scalable"/apps/gerbview.svg "$scalable"/apps/pcbnew.svg \
            "$scalable"/apps/pcbcalculator.svg "$scalable"/apps/bitmap2component.svg
        for mimetype in footprint pcb project schematic symbol worksheet; do
            rm -f "$scalable/mimetypes/application-x-kicad-$mimetype.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-16.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-24.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-32.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-48.svg" \
                "$scalable/mimetypes/application-x-kicad-$mimetype-64.svg"
        done
    fi

    rm -f "$prefix"/share/mime/packages/kicad-gerbers.xml \
        "$prefix"/share/mime/packages/kicad-kicad.xml

    rm -f "$prefix"/share/metainfo/org.kicad.kicad.metainfo.xml

    rm -f "$prefix"/share/bash-completion/completions/kicad-cli \
        "$prefix"/share/zsh/site-functions/_kicad-cli
}
```

- [ ] **Step 2: Write `uninstall-usr-local.sh`**

The no-manifest fallback list is derived from `dpkg-deb -c` against the built
`kicad_*.deb`, not guessed: KiCad's shared libraries land under the Debian
multiarch subdir (`lib/x86_64-linux-gnu/`), not bare `lib/`, and a
`/usr/local` build may use either, so both are checked. The fallback also
covers the seven `*.kiface` plugin modules, the four IDF utilities
(`dxf2idf`, `idf2vrml`, `idfcyl`, `idfrect`), the `plugins/3d/*.so` tree, and
the Python bindings (`pcbnew.py`, `_pcbnew.so`) -- all real `/usr/bin` and
`/usr/lib` entries in the built package that a stale `/usr/local` source
install would shadow if left behind. `/usr/local/bin` and `/usr/local/lib`
are shared with other software, so only the specific files KiCad owns are
removed from them; `share/kicad` and the multiarch/non-multiarch
`lib/.../kicad` subtrees are directories KiCad owns exclusively and can be
removed wholesale.

PATH shadowing is not the only shadowing mechanism: `XDG_DATA_DIRS` puts
`/usr/local/share/` ahead of `/usr/share/`, so a stale desktop entry, icon or
MIME definition left under `/usr/local/share` keeps winning over the one the
`.deb` installs, even after the executables above are gone -- the desktop
environment still shows an entry whose `Exec=kicad` now resolves through
PATH to nothing. `kicad_uninstall_remove_desktop_integration` (in
`lib/uninstall.sh`) removes exactly those files -- diffed empty against
`dpkg-deb -c` for `share/applications/org.kicad.*.desktop`,
`share/icons/hicolor/**` (apps and mimetypes, all six raster sizes plus
scalable), `share/mime/packages/kicad-*.xml`, `share/metainfo/`, and the
bash/zsh completions -- by exact filename, never a glob, since
`share/applications`, `share/icons/hicolor`, `share/mime` and the completion
directories are shared with other locally-installed software. The script
also refreshes `update-desktop-database`, `update-mime-database` and
`gtk-update-icon-cache` at the end when each tool exists and is non-fatal
when it doesn't: the `.deb`'s own refresh runs via dpkg triggers, but those
only fire for `/usr/share`, so a manual `/usr/local` cleanup gets none.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Remove a prior KiCad installed from source under /usr/local.
#
# /usr/local/bin precedes /usr/bin on the default PATH, so an old source install
# shadows the packaged one: apt reports success and the stale binary keeps
# running. This is deliberately NOT done from a maintainer script -- Debian
# Policy reserves /usr/local for the local administrator.

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/uninstall.sh
. "$SCRIPT_DIR/lib/uninstall.sh"

PREFIX=/usr/local
MANIFEST=${1:-}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must run as root" >&2
    exit 1
fi

if [ -n "$MANIFEST" ]; then
    if [ ! -r "$MANIFEST" ]; then
        echo "Error: manifest '$MANIFEST' does not exist or is not readable" >&2
        exit 1
    fi

    echo "Removing files listed in $MANIFEST"
    rejected=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if resolved=$(kicad_uninstall_resolve_under_prefix "$f" "$PREFIX"); then
            rm -f "$resolved"
        else
            echo "  rejecting out-of-prefix path: $f" >&2
            rejected=1
        fi
    done <"$MANIFEST"

    if [ "$rejected" -ne 0 ]; then
        echo "Error: manifest contained one or more paths outside $PREFIX" >&2
        exit 1
    fi
else
    echo "No install manifest given; removing known /usr/local KiCad paths"

    rm -rf "$PREFIX/share/kicad"

    # KiCad's shared libraries land under the Debian multiarch subdir
    # ($PREFIX/lib/x86_64-linux-gnu/), but a bare -DCMAKE_INSTALL_PREFIX
    # build can also put them straight in $PREFIX/lib -- cover both, and the
    # kiface plugin/3D-plugin tree each one may carry alongside them.
    for libdir in "$PREFIX/lib" "$PREFIX/lib/x86_64-linux-gnu"; do
        [ -d "$libdir" ] || continue
        rm -f "$libdir"/libkicommon.so* "$libdir"/libkiapi.so* \
            "$libdir"/libkicad_3dsg.so* "$libdir"/libkigal.so*
        rm -rf "$libdir/kicad"
    done

    rm -f "$PREFIX"/bin/kicad "$PREFIX"/bin/kicad-cli "$PREFIX"/bin/eeschema \
        "$PREFIX"/bin/pcbnew "$PREFIX"/bin/gerbview "$PREFIX"/bin/pl_editor \
        "$PREFIX"/bin/pcb_calculator "$PREFIX"/bin/bitmap2component \
        "$PREFIX"/bin/dxf2idf "$PREFIX"/bin/idf2vrml "$PREFIX"/bin/idfcyl \
        "$PREFIX"/bin/idfrect \
        "$PREFIX"/bin/_cvpcb.kiface "$PREFIX"/bin/_eeschema.kiface \
        "$PREFIX"/bin/_gerbview.kiface "$PREFIX"/bin/_kipython.kiface \
        "$PREFIX"/bin/_pcb_calculator.kiface "$PREFIX"/bin/_pcbnew.kiface \
        "$PREFIX"/bin/_pl_editor.kiface

    rm -f "$PREFIX"/lib/python3/dist-packages/pcbnew.py \
        "$PREFIX"/lib/python3/dist-packages/_pcbnew.so

    kicad_uninstall_remove_desktop_integration "$PREFIX"
fi

# Prune directories now left empty by the removals above. Restricted to
# subtrees KiCad owns exclusively and to already-empty results (-empty), so
# a directory still holding unrelated local files is never touched.
# $PREFIX/bin and $PREFIX/lib themselves are shared with other software and
# are never removed here, only the files placed directly in them above.
for d in "$PREFIX/share/kicad" "$PREFIX/lib/kicad" "$PREFIX/lib/x86_64-linux-gnu/kicad"; do
    [ -d "$d" ] || continue
    find "$d" -depth -type d -empty -delete
done

ldconfig

# The .deb's own desktop/MIME/icon caches are refreshed via dpkg triggers,
# but those triggers only fire for /usr/share; a manual /usr/local cleanup
# gets no trigger, so the caches are refreshed here explicitly. Each tool is
# optional on the host and its failure does not abort the script.
if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$PREFIX/share/applications" ]; then
    update-desktop-database "$PREFIX/share/applications" || true
fi
if command -v update-mime-database >/dev/null 2>&1 && [ -d "$PREFIX/share/mime" ]; then
    update-mime-database "$PREFIX/share/mime" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -d "$PREFIX/share/icons/hicolor" ]; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" || true
fi

echo "Done. /usr/local KiCad removed."
```

- [ ] **Step 3: Write `tests/uninstall.bats`**

Unit-tests `kicad_uninstall_resolve_under_prefix` as a pure function against
a fake tree under a temp directory -- never against `/usr/local`. Covers: a
normal path under the prefix, the prefix itself, a `..` traversal escaping
the prefix, a path outside the prefix, a blank input, a sibling path that
merely shares the prefix as a text string (e.g. `/usr/local-evil`, which a
slash-less `case` match would wrongly accept), a symlinked intermediate
component that escapes the prefix, and a nonexistent path under the prefix
(the already-removed-by-a-prior-run case `realpath -m` exists to support).

Also unit-tests `kicad_uninstall_remove_desktop_integration`: a no-op-without-
error run against an empty prefix, and a run against a fake tree seeded with
both KiCad's own desktop/icon/mime/metainfo/completion files and a decoy
belonging to another application in each of the shared directories (e.g.
`other-app.desktop`, an unrelated icon, an unrelated mime xml) -- asserts the
KiCad files are gone, the decoys and the containing directories both survive.

Create `tests/uninstall.bats`:

```bash
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

@test "desktop-integration removal is a no-op without error on an empty prefix" {
    run kicad_uninstall_remove_desktop_integration "$PREFIX"
    [ "$status" -eq 0 ]
}

@test "desktop-integration removal deletes KiCad's own files and leaves other software's files alone" {
    # applications/, icons/hicolor/, mime/packages/ and the completion dirs
    # are shared with whatever else is installed under this prefix -- seed
    # each with a KiCad file alongside a decoy belonging to another package,
    # and assert only the KiCad file is removed.
    mkdir -p "$PREFIX/share/applications"
    touch "$PREFIX/share/applications/org.kicad.kicad.desktop" \
        "$PREFIX/share/applications/org.kicad.eeschema.desktop" \
        "$PREFIX/share/applications/other-app.desktop"

    mkdir -p "$PREFIX/share/icons/hicolor/128x128/apps" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes" \
        "$PREFIX/share/icons/hicolor/scalable/apps" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes"
    touch "$PREFIX/share/icons/hicolor/128x128/apps/kicad.png" \
        "$PREFIX/share/icons/hicolor/128x128/apps/other-app.png" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-kicad-pcb.png" \
        "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-other-mime.png" \
        "$PREFIX/share/icons/hicolor/scalable/apps/kicad.svg" \
        "$PREFIX/share/icons/hicolor/scalable/apps/other-app.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb-16.svg" \
        "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-other-mime.svg"

    mkdir -p "$PREFIX/share/mime/packages"
    touch "$PREFIX/share/mime/packages/kicad-kicad.xml" \
        "$PREFIX/share/mime/packages/kicad-gerbers.xml" \
        "$PREFIX/share/mime/packages/other-app.xml"

    mkdir -p "$PREFIX/share/metainfo"
    touch "$PREFIX/share/metainfo/org.kicad.kicad.metainfo.xml" \
        "$PREFIX/share/metainfo/org.other-app.metainfo.xml"

    mkdir -p "$PREFIX/share/bash-completion/completions" "$PREFIX/share/zsh/site-functions"
    touch "$PREFIX/share/bash-completion/completions/kicad-cli" \
        "$PREFIX/share/bash-completion/completions/other-tool" \
        "$PREFIX/share/zsh/site-functions/_kicad-cli" \
        "$PREFIX/share/zsh/site-functions/_other-tool"

    kicad_uninstall_remove_desktop_integration "$PREFIX"

    # KiCad's own files are gone.
    [ ! -e "$PREFIX/share/applications/org.kicad.kicad.desktop" ]
    [ ! -e "$PREFIX/share/applications/org.kicad.eeschema.desktop" ]
    [ ! -e "$PREFIX/share/icons/hicolor/128x128/apps/kicad.png" ]
    [ ! -e "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-kicad-pcb.png" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/apps/kicad.svg" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb.svg" ]
    [ ! -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-kicad-pcb-16.svg" ]
    [ ! -e "$PREFIX/share/mime/packages/kicad-kicad.xml" ]
    [ ! -e "$PREFIX/share/mime/packages/kicad-gerbers.xml" ]
    [ ! -e "$PREFIX/share/metainfo/org.kicad.kicad.metainfo.xml" ]
    [ ! -e "$PREFIX/share/bash-completion/completions/kicad-cli" ]
    [ ! -e "$PREFIX/share/zsh/site-functions/_kicad-cli" ]

    # Files belonging to other, unrelated software survive untouched.
    [ -e "$PREFIX/share/applications/other-app.desktop" ]
    [ -e "$PREFIX/share/icons/hicolor/128x128/apps/other-app.png" ]
    [ -e "$PREFIX/share/icons/hicolor/128x128/mimetypes/application-x-other-mime.png" ]
    [ -e "$PREFIX/share/icons/hicolor/scalable/apps/other-app.svg" ]
    [ -e "$PREFIX/share/icons/hicolor/scalable/mimetypes/application-x-other-mime.svg" ]
    [ -e "$PREFIX/share/mime/packages/other-app.xml" ]
    [ -e "$PREFIX/share/metainfo/org.other-app.metainfo.xml" ]
    [ -e "$PREFIX/share/bash-completion/completions/other-tool" ]
    [ -e "$PREFIX/share/zsh/site-functions/_other-tool" ]

    # The shared containing directories themselves are never removed.
    [ -d "$PREFIX/share/applications" ]
    [ -d "$PREFIX/share/icons/hicolor" ]
    [ -d "$PREFIX/share/mime/packages" ]
    [ -d "$PREFIX/share/bash-completion/completions" ]
    [ -d "$PREFIX/share/zsh/site-functions" ]
}
```

- [ ] **Step 4: Lint**

Run: `shellcheck uninstall-usr-local.sh lib/uninstall.sh && shfmt -i 4 -ci -d uninstall-usr-local.sh lib/uninstall.sh`
Expected: no output.

- [ ] **Step 5: Write `README.md`**

`lintian` was dropped from the dependency list and Tests section: nothing in
this repo invokes it (no build step, no documented command), so listing it
as a dependency without ever showing its use is misleading. It was a
one-off manual check during Task 6 development, not a repeatable command
this repo exposes.

```markdown
# kicad-source-to-deb

Builds KiCad from source on Ubuntu 26.04 and packages it as two `.deb` files.

Companion to [saleae-logic2-appimage-to-deb](https://github.com/pdietl/saleae-logic2-appimage-to-deb).

## What you get

| Package | Installed | Contents |
|---|---|---|
| `kicad` | ~343 MB | binaries, symbols, footprints, templates, i18n, desktop integration |
| `kicad-packages3d` | ~1.2 GB | STEP models for the 3D viewer and STEP/VRML export |

`kicad-packages3d` is optional. The PCB editor canvas is 2D; without the models
the 3D viewer still renders board geometry, just no component bodies.

## Usage

    sudo apt-get install -y build-essential cmake ninja-build ccache dpkg-dev \
        git binutils fakeroot bats
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
    shellcheck *.sh lib/*.sh packaging/kicad.postinst
```

- [ ] **Step 6: Verify the tests referenced in the README actually pass**

Run: `bats tests/`
Expected: `39 tests, 0 failures` across the four test files (14 version, 8 shlibdeps,
6 stage, 11 uninstall).

- [ ] **Step 7: Commit**

```bash
chmod +x uninstall-usr-local.sh
git add --chmod=+x uninstall-usr-local.sh
git add lib/uninstall.sh tests/uninstall.bats README.md
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
