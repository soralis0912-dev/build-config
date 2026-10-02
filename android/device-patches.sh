#!/bin/bash
#
# Apply the patches a device tree carries for other projects, and take them
# back out.
#
#   device-patches.sh apply  <tree top> <device dir>
#   device-patches.sh revert <tree top>
#
# Device trees can carry fixes they need in projects outside the device tree
# (frameworks/base and so on) that are not, or not yet, in those projects:
#
#   <device dir>/patches/<project path, '/' replaced by '_'>/*.patch
#   e.g. device/xiaomi/warhol/patches/frameworks_base/0001-foo.patch
#
# Patches are applied in file name order with `git apply` and recorded under
# .repo/, so that revert can take out exactly what apply put in, newest first.
# apply reverts whatever a previous run left behind before it starts.
#
# - A patch that is already present (reverse-applies cleanly) is left alone
#   and not recorded, so nothing applied by other means is ever reverted.
# - If a patch fails to apply, everything applied so far is reverted and the
#   script fails, rather than building a half-patched tree.
# - Directories that do not name a project in .repo/project.list are skipped;
#   device trees also keep patches for prebuilt apps under patches/.

set -euo pipefail

usage() {
    echo "usage: $0 apply <tree top> <device dir> | revert <tree top>" >&2
    exit 2
}

revert() {
    local top=$1
    local state=$top/.repo/witaqua-device-patches
    [ -f "$state/list" ] || return 0

    local ret=0 i project patch
    local -a entries
    mapfile -t entries < "$state/list"
    for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
        project=${entries[$i]%%$'\t'*}
        patch=$state/${entries[$i]#*$'\t'}
        if git -C "$top/$project" apply --check --reverse "$patch" 2>/dev/null; then
            git -C "$top/$project" apply --reverse "$patch"
            echo "Reverted device patch: $project"
        elif git -C "$top/$project" apply --check "$patch" 2>/dev/null; then
            # Already gone, e.g. the sync reset the project.
            :
        else
            echo "Could not revert device patch in $project; keeping $state" >&2
            ret=1
        fi
    done
    [ $ret -ne 0 ] || rm -rf "$state"
    return $ret
}

apply() {
    local top=$1 device_dir=$2
    local state=$top/.repo/witaqua-device-patches

    revert "$top"
    [ -d "$top/$device_dir/patches" ] || return 0

    local n=0 dir name project patch entry
    mkdir -p "$state"
    for dir in "$top/$device_dir"/patches/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        project=$(awk -v n="$name" '{ k = $0; gsub("/", "_", k); if (k == n) { print; exit } }' \
            "$top/.repo/project.list")
        if [ -z "$project" ] || [ ! -d "$top/$project" ]; then
            continue
        fi
        for patch in "$dir"*.patch; do
            [ -f "$patch" ] || continue
            if git -C "$top/$project" apply --check --reverse "$patch" 2>/dev/null; then
                echo "Device patch already present, leaving it: $project: $(basename "$patch")"
                continue
            fi
            if ! git -C "$top/$project" apply "$patch"; then
                echo "Failed to apply device patch: $project: $(basename "$patch")" >&2
                revert "$top" || true
                return 1
            fi
            n=$((n + 1))
            entry=$(printf '%03d.patch' $n)
            cp "$patch" "$state/$entry"
            printf '%s\t%s\n' "$project" "$entry" >> "$state/list"
            echo "Applied device patch: $project: $(basename "$patch")"
        done
    done
}

case "${1:-}" in
    apply)  [ $# -eq 3 ] || usage; apply "$2" "$3" ;;
    revert) [ $# -eq 2 ] || usage; revert "$2" ;;
    *)      usage ;;
esac
