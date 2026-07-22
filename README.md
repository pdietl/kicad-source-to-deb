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

KiCad's own build dependencies (from upstream's `install-deps.sh`), plus this repo's build
and packaging tooling:

    sudo apt-get install -y build-essential cmake ninja-build ccache dpkg-dev \
        git binutils fakeroot bats shellcheck \
        libwxgtk3.2-dev libwxgtk-webview3.2-dev libocct-foundation-dev \
        libocct-data-exchange-dev libocct-modeling-algorithms-dev \
        libocct-modeling-data-dev libocct-visualization-dev libocct-ocaf-dev \
        swig python3-dev python3-wxgtk4.0 libglm-dev libgit2-dev \
        libsecret-1-dev libcurl4-openssl-dev libngspice0-dev libnng-dev \
        libboost-all-dev libcairo2-dev libglu1-mesa-dev libgl1-mesa-dev \
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
    shfmt -i 4 -ci -d *.sh lib/*.sh
