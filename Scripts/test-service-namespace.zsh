#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
runDir="$(mktemp -d "$PWD/.build/service-namespace.XXXXXX")"
xcrun swiftc -swift-version 5 -parse-as-library \
    Sources/TalkTuckAccountStore.swift Sources/LibrarySync.swift Sources/RecordingDomain.swift \
    Sources/ServiceNamespaceMigration.swift Tests/ServiceNamespaceMigrationSmoke.swift -o "$runDir/migration-smoke"
"$runDir/migration-smoke" "$runDir"
