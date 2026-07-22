# kicad-source-to-deb — design

Build KiCad 10.0.5-rc1 and its library repos from source on Ubuntu 26.04, and package the
result as two `.deb` files installable with `apt`. Companion to
`pdietl/saleae-logic2-appimage-to-deb`, and consumed by `dev_tools/provision`.

## Problem

KiCad ships an official AppImage, but an AppImage gives no dash-searchable, pinnable desktop
entry without extra work, and its runtime paths live under a per-launch FUSE mount. Ubuntu's
archive package is 9.0.9. Building from source produces a correct system installation, but the
knowledge required is spread across five repositories, a packaging repo, and several non-obvious
CMake options — none of it captured anywhere reusable.

This repo captures it: one `west` manifest pinning every input, one script that goes from a bare
checkout to installable packages.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Multi-repo tool | `west` | Per-project `clone-depth` and tag `revision`; manifest lives in this repo via `self`. Pins stay data, not logic. |
| Package split | Two debs | `kicad` (~343 MB installed) and `kicad-packages3d` (1.2 GB installed). Lets a machine skip the models. |
| Debug info | Stripped | 94% of binary size. Matches the official build, which strips and serves symbols via debuginfod. |
| Demos | Excluded | `KICAD_INSTALL_DEMOS=OFF`. 151 MB of sample projects. |
| Install prefix | `/usr` | Matches the official builder. Debian Policy forbids packages writing to `/usr/local`. |
| Build location | Local, at provision time | No CI. No release assets to publish or forget. The build script is the only path, so it cannot rot from disuse. |

### Rejected

- **CI-built release assets.** Would need a public repo plus a manual `gh release create` per
  version bump, to save ~45 min on an operation performed a few times a year. A rarely-exercised
  fallback path stops working quietly and is discovered on the day it is needed.
- **`/opt` or `/usr/lib/kicad-10` with wrappers.** Buys coexistence with the archive package,
  which is not wanted — this *is* the machine's KiCad. Costs six wrapper scripts, because every
  shipped `.desktop` uses a bare `Exec=kicad`.
- **git submodules.** Pin commit SHAs rather than tags, turning a version bump into SHA-chasing.

## Layout

West places its `.west/` directory in the workspace root, one level above this repo:

```
kicad-workspace/
├── .west/
├── kicad-source-to-deb/          this repo (west manifest repo)
│   ├── west.yml
│   ├── build-kicad-deb.sh
│   ├── uninstall-usr-local.sh
│   ├── packaging/
│   │   ├── kicad.control.in
│   │   ├── kicad.postinst
│   │   ├── kicad.triggers
│   │   └── kicad-packages3d.control.in
│   ├── README.md
│   └── .gitignore
├── kicad/
├── kicad-symbols/
├── kicad-footprints/
├── kicad-templates/
└── kicad-packages3D/
```

## west.yml

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
    # `git describe`, which needs commit counts.
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

Clone over HTTPS: KiCad's canonical host is GitLab, and anonymous HTTPS needs no key. The GitHub
mirrors of the library repos are archived and frozen at tag `5.1.7` — cloning them would pair a
v10 binary with v5.1 library data.

Bumping to a new KiCad release is a five-line change to `revision:` values.

## build-kicad-deb.sh

Conventions follow `saleae-logic2-appimage-to-deb`: `set -euo pipefail`, colour helpers, a tool
preflight loop, `mktemp -d` staging with `trap cleanup EXIT`, finished `.deb` files left in the
invocation directory.

1. **Preflight.** Require `west cmake ninja g++ dpkg-deb dpkg-shlibdeps git strip file fakeroot
   ccache`. `fakeroot` and `ccache` are both used well after this preflight -- `ccache` from the
   first compile, `fakeroot` only at packaging time -- so a missing one would otherwise burn most
   of a 30-50 minute build before surfacing. Fail with the apt command that supplies anything
   missing.
2. **Sync.** `west update`. The workspace must already be initialised (`west init -l`); README and
   `provision` do that once, before this script ever runs.
3. **Configure.**
   ```
   cmake -S ../kicad -B build -G Ninja \
       -DCMAKE_BUILD_TYPE=RelWithDebInfo \
       -DCMAKE_INSTALL_PREFIX=/usr \
       -DDEFAULT_INSTALL_PATH=/usr \
       -DKICAD_BUILD_I18N=ON \
       -DKICAD_USE_CMAKE_FINDPROTOBUF=ON \
       -DKICAD_BUILD_QA_TESTS=OFF \
       -DKICAD_INSTALL_DEMOS=OFF \
       -DCMAKE_C_COMPILER_LAUNCHER=ccache \
       -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
   ```
4. **Build.** `cmake --build build -j"$(nproc)"`.
5. **Stage.** Two independent `DESTDIR` trees:
   - `stage-kicad`: `DESTDIR=$STAGE_KICAD cmake --install build`, then the symbols, footprints
     and templates repos installed into the same tree with
     `-DCMAKE_INSTALL_PREFIX=/usr`. Symbols use `-DKICAD_PACK_SYM_LIBRARIES=OFF`.
   - `stage-3d`: only `kicad-packages3D`, same prefix.
6. **Strip.** `strip --strip-unneeded` every ELF file in `stage-kicad`. See below.
7. **Control generation.** Substitute version, architecture, `Installed-Size`
   (`du -sk <tree>/usr`) and the computed dependency list into the `.in` templates.
8. **Package.** `dpkg-deb --build` each tree; move both to the invocation directory.

### Stripping

Debug information is **94% of binary size**, measured: the staged binaries and shared objects
total ~256 MB unstripped and ~15 MB stripped.

Stripping is what parity requires, not a deviation from it. The official builder compiles
`RelWithDebInfo`, then runs `objcopy --only-keep-debug` to extract symbols, indexes them by
build-id, `strip --strip-unneeded`s every ELF, and ships `DEBUGINFOD_URLS=https://debuginfod.kicad.org`
so debuggers fetch symbols on demand. The binary a user runs is stripped; the debug info lives
out of band.

This repo keeps the `RelWithDebInfo` compile — it costs nothing at runtime and matches upstream —
and strips at packaging time. It does **not** produce a `kicad-dbg` package: with no debuginfod
service to publish to, the debug info has no consumer, and anyone needing to debug KiCad itself
can rebuild locally without the strip step.

### Build-type rationale

`RelWithDebInfo`, not `Release`. All four official recipes — AppImage, Flatpak, Ubuntu PPA and
Snap — independently use it. The AppImage's `configs/release-*.json` carries
`"build_type": "Release"`, but that is the *pipeline* type; its `Dockerfile` hardcodes
`-DCMAKE_BUILD_TYPE=RelWithDebInfo` and never passes the JSON value to CMake.

### Options that would silently drop a feature

`KICAD_BUILD_I18N` defaults **OFF**. With it off there are no translations, and the
`.desktop`/`.metainfo`/MIME metadata is emitted untranslated because the generator downgrades
from translate to plain copy. No warning is printed. The official build sets it ON.

`KICAD_USE_CMAKE_FINDPROTOBUF` defaults OFF; the AppImage, PPA and Snap all set it ON.

Flags that do **not** exist in KiCad 10 and must not be passed — CMake reports them only as
"Manually-specified variables were not used": `KICAD_USE_OCC` (OpenCASCADE is now unconditionally
required, minimum 7.5.0), `KICAD_SPICE`, `KICAD_USE_EGL`, `KICAD_USE_3DCONNEXION`,
`KICAD_STOCK_DATA_PATH`.

## Packages

| | `kicad` | `kicad-packages3d` |
|---|---|---|
| Contents | binaries, shared libs, symbols, footprints, templates, i18n, desktop/icon/MIME data | `/usr/share/kicad/3dmodels` only |
| Installed | ~343 MB (stripped) | ~1.2 GB |
| Compressed | not yet measured | ~115 MB (from a 10.7:1 sample) |
| Depends | computed, see below | `kicad (= <exact version>)` |
| Recommends | `kicad-packages3d` | — |
| Conflicts/Provides/Replaces | `kicad-symbols`, `kicad-footprints`, `kicad-templates` (versioned, so the archive's `kicad-libraries (>= 9.0.0~)` still resolves) | — |

`kicad`'s installed size is dominated by `share/kicad` -- symbols, footprints, templates and
i18n data -- with 3dmodels (1176 MB) and demos (150 MB) excluded and stripped binaries and
libraries a small fraction of the total.

The 3D models are 7,242 `.step` files — plain text, measured to compress 10.7:1 on a
three-directory sample — so the larger package is roughly a 115 MB download despite installing
1.2 GB. The `kicad` package's compressed size is dominated by already-compact library data and
has not been measured; the build script should report both.

`Recommends` rather than `Depends` on the models: KiCad is fully functional without them. The
PCB editor canvas is 2D; only the separate 3D viewer frame and the STEP/VRML exporter read the
model path. Without the package the 3D viewer still renders board geometry, just no component
bodies.

The package is named `kicad` deliberately. At `10.0.5~rc1-1` it outranks Ubuntu's
`9.0.9~ubuntu26.04.1`, so it supersedes the archive package rather than competing with it.

### Version munging

`10.0.5-rc1` must become `10.0.5~rc1-1`.

dpkg reads `-` as the separator between upstream version and Debian revision, so a literal
`10.0.5-rc1` parses as upstream `10.0.5`, revision `rc1`. When 10.0.5 final is later packaged as
`10.0.5-1`, dpkg compares revision `rc1` against `1` and treats the final release as a
**downgrade**, which `apt upgrade` refuses. `~` sorts before everything, giving the required
`10.0.5~rc1-1 < 10.0.5-1`.

The script derives the upstream version from `git -C ../kicad describe --tags` and replaces the
first `-` with `~` only when the suffix is a pre-release marker (`rc`, `beta`, `alpha`).

### Dependencies

`Depends` is computed by `dpkg-shlibdeps` against the staged binaries and shared objects, not
hand-maintained. A static list silently rots as upstream dependencies change; the tool reads the
actual `NEEDED` entries.

Two constraints were confirmed by running it, and both must be handled or the step fails outright:

- **It requires a `debian/control` file to exist**, even though this repo builds packages with
  `dpkg-deb --build` rather than a Debian source package. Without one it exits with
  `cannot read debian/control`. The script writes a minimal two-stanza `debian/control` into a
  scratch directory and runs `dpkg-shlibdeps` from there.
- **It cannot resolve KiCad's own libraries**, which belong to no installed package:
  `no dependency information found for libkicommon.so.10.0.5`. Pass `-l<stage>/usr/lib` so the
  private libraries are found locally, and `--ignore-missing-info` so their absence from any
  package is not fatal.

Output is captured with `-O`, which prints `shlibs:Depends=...` to stdout instead of writing a
substvars file.

**Substitution variables are not available.** `${binary:Version}`, `${shlibs:Depends}` and
friends are expanded by `dpkg-gencontrol`, which is part of the debhelper flow and is never
invoked here. A `dpkg-deb --build` package must have every field literal, so the script
substitutes the concrete version and dependency strings into the `.in` templates itself.

Computed dependencies tie the package to the distribution release it was built on. `provision`
already refuses to run on anything but Ubuntu 26.04, so that constraint is enforced upstream of
this repo.

### Maintainer scripts

Cache refreshes are dpkg-trigger-driven, not called from a maintainer script. `kicad.triggers`
declares `activate-noawait ldconfig`: `libc-bin` exposes `ldconfig` as a *named* trigger, so a
package shipping shared libraries opts in rather than calling `ldconfig` itself. `ldconfig` is
required regardless of mechanism: KiCad sets no `INSTALL_RPATH` on Linux and installs
`libkicommon.so` and friends into the library path, so without a cache refresh every binary fails
to start.

The other three caches need nothing from this repo at all: `desktop-file-utils`,
`shared-mime-info` and `hicolor-icon-theme` declare **path-based** triggers on
`/usr/share/applications`, `/usr/share/mime/packages` and `/usr/share/icons/hicolor`. Installing
files into those paths fires `update-desktop-database`, `update-mime-database` and the icon-cache
rebuild automatically; calling them from a maintainer script would duplicate work dpkg already
does. All four triggers fire on both install and removal, so there is no `postrm`.

`kicad.postinst` exists solely for the two `/usr/local` migration warnings described below.
`kicad-packages3d` ships no maintainer scripts and no triggers at all: it is pure data, with no
executables, shared libraries, desktop files or icons for any cache to refresh.

## Migration from a `/usr/local` source install

A machine that already has KiCad installed under `/usr/local` needs two things done, and neither
belongs in a maintainer script: `/usr/local` is administrator territory, and a package must not
edit files in a user's home directory.

**`/usr/local` shadows the package.** `/usr/local/bin` precedes `/usr/bin` on the default `PATH`,
so an existing `/usr/local/bin/kicad` continues to run after the package is installed.
`uninstall-usr-local.sh` removes the old installation using the `install_manifest.txt` written by
the original `cmake --install`, falling back to an explicit path list if the manifest is absent.

**The library table chains by absolute path.** On first run KiCad writes
`~/.config/kicad/<ver>/sym-lib-table` with a single row pointing at
`<prefix>/share/kicad/template/sym-lib-table`. That URI is absolute and is never revisited. Only
the *inner* rows of the template file use `${KICAD10_*_DIR}` variables. Changing prefix therefore
leaves the chain pointing at a path that no longer exists, and the failure is silent: the loader
emits a `wxLogTrace` and the user sees an empty library list with no dialog.

The fix is to delete `sym-lib-table`, `fp-lib-table` and `design-block-lib-table` from the profile
so they re-seed against the new prefix.

`postinst` **detects and warns** about both conditions. `provision` performs the actual removal
and profile reset, because it already runs as root and knows `$SUDO_USER`.

## provision integration

A block modelled on the existing Saleae section, guarded by the same `dpkg-query` status test so
it is idempotent:

```bash
if in_wsl; then
    echo "  KiCad: skipped (WSL)"
elif dpkg-query -Wf'${db:Status-abbrev}' kicad 2>/dev/null | grep -q '^i'; then
    echo "  KiCad: already installed"
else
    echo "  KiCad: building from source (~45 min)..."
    # clone workspace, run build-kicad-deb.sh, apt install both debs,
    # then run uninstall-usr-local.sh and reset the user's lib tables
fi
```

The build is expensive but runs once per machine. It is placed after the `build-essential` /
`cmake` / `ninja-build` / `ccache` package installation it depends on, all of which `provision`
already installs.

## Verification

After install, on a machine with no prior KiCad profile:

| Check | Expected |
|---|---|
| `which kicad` | `/usr/bin/kicad` — not `/usr/local/bin` |
| `kicad-cli version` | `10.0.5` |
| `python3 -c "import pcbnew; print(pcbnew.GetBuildVersion())"` | `10.0.5-rc1` |
| `grep -o 'uri "[^"]*"' ~/.config/kicad/10.0/sym-lib-table` | a path under `/usr/share/kicad` |
| `gtk-launch org.kicad.kicad` | launches |
| `gio mime application/x-kicad-project` | resolves to `org.kicad.kicad.desktop` |
| Preferences → Manage Symbol Libraries | populated, not empty |
| View → 3D Viewer | component bodies present when `kicad-packages3d` installed |

## Risks

**SWIG against a new CPython.** KiCad declares only minimums (`PythonInterp` 3.6, `SWIG` 4.0) and
no maximum. SWIG 4.4.0 against Python 3.14.4 was verified working by building it and importing
the module. A future Python bump could break the bindings; the escape hatch is
`-DKICAD_SCRIPTING_WXPYTHON=OFF`, which yields a working KiCad without the Python console.

**`clone-depth` with a tag revision.** West's `clone-depth` is documented as limiting history to a
number of commits. Its interaction with a tag `revision` has not been exercised here. If a shallow
clone cannot resolve the tag, drop `clone-depth` for that project — the cost is clone time, not
correctness.

**wxWidgets EGL.** Ubuntu's wxWidgets 3.2.9 reports `wxUSE_GLCANVAS_EGL=0`, where the official
AppImage builds wx 3.3.2 with EGL enabled. Flathub pins wx 3.2.x with an explicit cap below 3.3,
and the Ubuntu PPA uses the distro build, so this configuration is one upstream ships. Expect
cosmetic GL differences, not functional ones.

**Build resource use.** The build tree reaches roughly 15–25 GB with debug info, and
`RelWithDebInfo` link steps are the memory peak. `-j$(nproc)` on a 24-core machine may need
reducing under memory pressure.
