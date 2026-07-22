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
