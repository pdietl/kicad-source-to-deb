# kicad-source-to-deb

Builds KiCad from source on Ubuntu 26.04 and packages it as three `.deb` files.

Companion to [saleae-logic2-appimage-to-deb](https://github.com/pdietl/saleae-logic2-appimage-to-deb).

## What you get

| Package | Installed | Contents |
|---|---|---|
| `kicad` | ~343 MB | binaries, symbols, footprints, templates, i18n, desktop integration |
| `kicad-packages3d` | ~1.2 GB | STEP models for the 3D viewer and STEP/VRML export |
| `kicad-dbgsym` | ~1.9 GB | separated debug info, for reading a backtrace |

Only `kicad` is required. The PCB editor canvas is 2D, so without
`kicad-packages3d` the 3D viewer still renders board geometry, just no
component bodies. `kicad-dbgsym` matters only when something crashes or
hangs -- see [Debug symbols](#debug-symbols).

## Usage

KiCad's own build dependencies (from upstream's `install-deps.sh`), plus this repo's build
and packaging tooling:

    sudo apt-get install -y build-essential cmake ninja-build ccache dpkg-dev \
        git binutils fakeroot bats shellcheck \
        libwxgtk3.2-dev libwxgtk-webview3.2-dev libocct-foundation-dev \
        libocct-data-exchange-dev libocct-modeling-algorithms-dev \
        libocct-modeling-data-dev libocct-visualization-dev libocct-ocaf-dev \
        swig python3-dev python3-wxgtk4.0 libglm-dev libgit2-dev \
        libsecret-1-dev libcurl4-openssl-dev libngspice0-dev libnng-dev \
        libboost-all-dev libcairo2-dev libfontconfig-dev libfreetype-dev \
        libharfbuzz-dev libpixman-1-dev libgtk-3-dev libwayland-dev \
        libglu1-mesa-dev libgl1-mesa-dev \
        libprotobuf-dev protobuf-compiler gettext unixodbc-dev libspnav-dev \
        libzint-dev libpoppler-dev libpoppler-glib-dev zlib1g-dev libssl-dev \
        libzstd-dev libbz2-dev shared-mime-info
    pipx install west

    git clone https://github.com/pdietl/kicad-source-to-deb.git
    cd kicad-source-to-deb
    ./build-kicad-deb.sh

The script bootstraps its own west workspace under `work/` on first run --
no separate `west init`/`west update` step is needed first.

The build takes 30-50 minutes and needs roughly 25 GB of scratch space.
`work/` is scratch: delete it any time to force a clean rebuild from fresh
checkouts.

    sudo apt install ./kicad_*.deb ./kicad-packages3d_*.deb

Name both files. `kicad` recommends `kicad-packages3d` at exactly its own
version, so naming only the first leaves the recommendation unsatisfied and
apt installs `kicad` alone -- rather than resolving the name against a
configured repository and pulling a 3D-model package from a different KiCad
release, which is what an unversioned recommendation invites when the KiCad
PPA is enabled.

## Debug symbols

The build compiles with debug info and then separates it: `kicad-dbgsym`
carries it, and the binaries in `kicad` are stripped. Debug info is ~96% of
binary size, so it cannot stay in the main package, but discarding it makes
every backtrace a list of hex addresses.

    sudo apt install ./kicad-dbgsym_*.deb

Nothing needs configuring afterwards. The debug files are indexed by build ID
under `/usr/lib/debug/.build-id`, which is where gdb already looks, so
function names, source files and line numbers reappear on their own. The
`kicad` package is byte-for-byte identical whether or not this is installed,
so it can be added while chasing one bug and removed after.

Debug files are matched to binaries by build ID, not by version, so
`kicad-dbgsym` only resolves symbols for the `kicad` build it was produced
alongside. A rebuild reuses the version string, so apt cannot tell two builds
apart and will not stop you installing them out of step -- the only symptom
is that no symbols appear. To confirm a match:

    bid=$(readelf -n /usr/bin/_pcbnew.kiface | awk '/Build ID:/ {print $3}')
    ls "/usr/lib/debug/.build-id/${bid:0:2}/${bid:2}.debug"

To capture where a hung KiCad is stuck:

    sudo gdb -p "$(pgrep -x kicad)" -batch -ex 'thread apply all bt'

`sudo` is required whenever `/proc/sys/kernel/yama/ptrace_scope` is 1 (the
Ubuntu default): a debugger may otherwise only attach to its own descendants.

## Profiling the canvas

For a breakdown of where a single frame's time goes, build with the GAL
timers compiled in, then run KiCad with their trace mask selected:

    KICAD_GAL_PROFILE=ON ./build-kicad-deb.sh
    KICAD_TRACE=KICAD_GAL_PROFILE kicad

KiCad then writes `Timing: <total> <cached> <noncached> <overlay> <composite>
<swap>` per frame to stderr. The timers are off by default because they cost
time inside the render loop they measure.

`KICAD_TRACE` is a separate channel from `KICAD_ENABLE_WXTRACE`, and both use
the same mask names; setting only the latter leaves these lines unemitted.

## Patches

`patches/kicad/*.patch` are applied to the KiCad checkout after the workspace
syncs, in numeric order. Each one exists to make the build warning-free on the
toolchain in `build-kicad-deb.sh`'s supported target; the header of each patch
says what it fixes and why.

Applying is idempotent and never resets the checkout, because `west update`
carries uncommitted changes forward rather than discarding them -- a patch
already present is detected and skipped, so local edits to the source tree
survive a rebuild. A patch that neither applies nor is already applied stops
the build rather than being skipped, since a silently dropped patch reinstates
whatever it fixed.

To add one, edit `work/kicad`, then capture just that change:

    git -C work/kicad diff -- path/to/file > patches/kicad/000N-summary.patch

and prepend a short prose header explaining the reason (`git apply` ignores
leading text). `bats tests/patch.bats` checks the whole set still applies.

Two CMake policy warnings are *not* patched: KiCad sets CMP0116 and CMP0113 to
OLD deliberately, each for a documented reason, so `build-kicad-deb.sh` passes
`-Wno-deprecated` instead. It intentionally does not pass `-Wno-dev`, which
would also suppress developer warnings worth seeing.

## Upgrading to a new KiCad release

Edit the five `revision:` values in `west.yml`, then rerun `./build-kicad-deb.sh` --
it syncs the workspace to the new revisions before building.

A revision bump can strand a patch. `bats tests/patch.bats` reports that against
the current checkout in seconds, rather than letting the build discover it.

## If a source install came first

`/usr/local/bin` precedes `/usr/bin` on PATH, so a KiCad previously installed
under `/usr/local` keeps running after the package is installed, and apt
reports success either way. Remove it before believing the package is live.

KiCad also writes an absolute path into the per-user library table on first run
and never revisits it, so a prefix change leaves the library list silently
empty. Reset it:

    rm ~/.config/kicad/10.0/{sym,fp,design-block}-lib-table

They are re-seeded against the new prefix on next launch.

## Tests

    bats tests/
    shellcheck *.sh lib/*.sh packaging/kicad.postinst
    shfmt -i 4 -ci -d *.sh lib/*.sh
