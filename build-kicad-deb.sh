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
# ccache and fakeroot are both used well after this preflight -- ccache from
# the very first compile ("Configuring KiCad" wires it in via
# CMAKE_*_COMPILER_LAUNCHER but the failure surfaces at first compile,
# 30-50 minutes in), fakeroot only at packaging time in build_package(). A
# missing tool discovered at either point burns the whole build for
# something this loop already checks everything else for.
for tool in west cmake ninja g++ dpkg-deb dpkg-shlibdeps git strip file fakeroot ccache; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${RED}Error: $tool is not installed${NC}"
        echo "Install build tooling with: sudo apt-get install -y \\"
        echo "    build-essential cmake ninja-build ccache dpkg-dev git binutils fakeroot"
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
# mktemp -d makes these mode 0700. dpkg-deb -x later chmods the extraction
# destination to match the archive's own "./" entry, so a 0700 staging root
# would make every install of this package unreadable to non-root users.
chmod 0755 "$STAGE_KICAD" "$STAGE_3D"

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
# Thresholds are well below a real install (thousands of files) and well
# above zero -- see the comment on kicad_assert_min_files for why a bare
# non-empty check does not catch an install that silently produced almost
# nothing.
kicad_assert_min_files "$STAGE_KICAD/usr" 200 "kicad main install"

# Symbols ship as unpacked .kicad_symdir directories; packing is off to match
# what the official build installs.
stage "Staging kicad-symbols"
cmake -S "$WORKSPACE/kicad-symbols" -B "$LIB_BUILD_ROOT/kicad-symbols" -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/usr -DKICAD_PACK_SYM_LIBRARIES=OFF
DESTDIR=$STAGE_KICAD cmake --install "$LIB_BUILD_ROOT/kicad-symbols"
kicad_assert_min_files "$STAGE_KICAD/usr/share/kicad/symbols" 1000 "kicad-symbols"

for lib in kicad-footprints kicad-templates; do
    stage "Staging $lib"
    cmake -S "$WORKSPACE/$lib" -B "$LIB_BUILD_ROOT/$lib" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr
    DESTDIR=$STAGE_KICAD cmake --install "$LIB_BUILD_ROOT/$lib"
done
kicad_assert_min_files "$STAGE_KICAD/usr/share/kicad/footprints" 1000 "kicad-footprints"
kicad_assert_min_files "$STAGE_KICAD/usr/share/kicad/template" 20 "kicad-templates"

# The models go straight into their own tree: this repo's CMake installs only
# the shape directories, so no post-hoc move is needed.
stage "Staging 3D models"
cmake -S "$WORKSPACE/kicad-packages3D" -B "$LIB_BUILD_ROOT/kicad-packages3D" \
    -G Ninja -DCMAKE_INSTALL_PREFIX=/usr
DESTDIR=$STAGE_3D cmake --install "$LIB_BUILD_ROOT/kicad-packages3D"
kicad_assert_min_files "$STAGE_3D/usr/share/kicad/3dmodels" 1000 "kicad-packages3d"

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

    # dpkg-deb --build catches an unsubstituted @VERSION@ or @DEPENDS@ on its
    # own -- both land in a field dpkg validates (a bad package name/version,
    # a malformed dependency). @INSTALLED_SIZE@ lands in a field dpkg does
    # not validate the syntax of, so a template gaining a new placeholder
    # this script forgets to substitute would otherwise build successfully
    # with the literal text "@INSTALLED_SIZE@" shipped as the size.
    if [[ $control == *@*@* ]]; then
        echo -e "${RED}Error: unsubstituted @..@ placeholder remains in" \
            "$name control file${NC}" >&2
        exit 1
    fi

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
