#!/bin/bash
# Builds the Core together with the integration test and runs it. Needs no GUI and no second Mac:
# both sides run in one process over loopback, and the share is synced between two folders, also over the encrypted link.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/sharekeeper-tests"
swiftc -O -swift-version 5 Sources/Core/*.swift Tests/main.swift -o "$OUT"
"$OUT"
