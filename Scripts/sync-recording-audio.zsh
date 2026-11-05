#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
files=(ResilientRecordingJournal.swift BalancedWatchSync.swift CanonicalAudioReader.swift CanonicalAudioExport.swift)
manifest="Sources/RecordingAudio.sha256"
case "${1:---check}" in
  --check)
    shasum -a 256 -c "$manifest"
    ;;
  --sync)
    [[ $# == 2 && -d "$2/app/Shared" ]] || { print -u2 'Usage: sync-recording-audio.zsh --sync /path/to/recordai'; exit 2; }
    for file in $files; do [[ -f "$2/app/Shared/$file" ]] || { print -u2 "Missing $file"; exit 1; }; done
    for file in $files; do cp "$2/app/Shared/$file" "Sources/$file"; done
    shasum -a 256 "${files[@]/#/Sources/}" > "$manifest"
    ;;
  *) print -u2 'Usage: sync-recording-audio.zsh [--check | --sync /path/to/recordai]'; exit 2 ;;
esac
