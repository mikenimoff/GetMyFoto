#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -swift-version 5 -module-cache-path .build/ModuleCache Sources/Storage.swift Sources/ConnectionPolicy.swift Sources/MediaSelection.swift Tests/main.swift -o .build/StorageTests
.build/StorageTests
