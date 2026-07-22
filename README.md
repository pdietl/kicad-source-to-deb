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
        git binutils fakeroot bats shellcheck
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
