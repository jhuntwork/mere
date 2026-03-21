#!/bin/sh
set -eu

parse_version() {
    sed -n 's/^[[:space:]]*\.version = "\(.*\)",[[:space:]]*$/\1/p' "$1" | head -n 1
}

detect_version_change() {
    current_file=$1
    previous_file=${2-}

    new_version=$(parse_version "$current_file")
    if [ -z "$new_version" ]; then
        printf '%s\n' "Unable to parse version from $current_file" >&2
        exit 1
    fi

    old_version=""
    if [ -n "$previous_file" ] && [ -f "$previous_file" ]; then
        old_version=$(parse_version "$previous_file")
    fi

    version_changed=false
    if [ "$new_version" != "$old_version" ]; then
        version_changed=true
    fi

    printf 'version=%s\n' "$new_version"
    printf 'old_version=%s\n' "$old_version"
    printf 'tag=v%s\n' "$new_version"
    printf 'release_name=mere %s\n' "$new_version"
    printf 'version_changed=%s\n' "$version_changed"
}

asset_base() {
    version=$1
    os=$2
    arch=$3
    printf 'mere-%s-%s-%s\n' "$version" "$os" "$arch"
}

case "${1-}" in
    detect-version-change)
        shift
        detect_version_change "$@"
        ;;
    asset-base)
        shift
        asset_base "$@"
        ;;
    *)
        printf '%s\n' "usage: $0 detect-version-change <current> [previous]" >&2
        printf '%s\n' "   or: $0 asset-base <version> <os> <arch>" >&2
        exit 1
        ;;
esac
