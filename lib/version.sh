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
