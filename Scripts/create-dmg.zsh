#!/bin/zsh
# Build a distributable image without the folder-to-image API (busy on some macOS hosts).
set -euo pipefail
sourceFolder="${1:?Pass a staging folder}"
outputImage="${2:?Pass an output .dmg path}"
volumeName="${3:-TalkTuck}"
[[ -d "$sourceFolder" && ! -e "$outputImage" ]]
work="$(mktemp -d "${TMPDIR:-/tmp}/talktuck-dmg.XXXXXX")"
mountPath="$work/mount"
mounted=0
cleanup() {
    if (( mounted )); then
        if ! hdiutil detach "$mountPath" >/dev/null; then
            print -u2 "Cannot detach packaging volume; retained $work"
            return
        fi
    fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
sourceKiB="$(du -sk "$sourceFolder" | awk '{print $1}')"
sizeMiB=$(( sourceKiB / 1024 + sourceKiB / 10240 + 128 ))
hdiutil create -size "${sizeMiB}m" -fs HFS+ -volname "$volumeName" -type UDIF "$work/writable.dmg"
mkdir "$mountPath"
hdiutil attach -nobrowse -noautoopen -mountpoint "$mountPath" "$work/writable.dmg" >/dev/null
mounted=1
ditto "$sourceFolder" "$mountPath"
hdiutil detach "$mountPath" >/dev/null
mounted=0
hdiutil convert "$work/writable.dmg" -format UDZO -o "$outputImage"
hdiutil verify "$outputImage"
