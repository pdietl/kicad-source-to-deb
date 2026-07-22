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
