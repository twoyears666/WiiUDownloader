#!/usr/bin/env bash
#
# Build the gomobile XCFramework that the WiiUCore package links against as its
# `Mobile` binary target. Requires Go, the iOS SDK (Xcode) and gomobile:
#
#     go install golang.org/x/mobile/cmd/gomobile@latest
#     go install golang.org/x/mobile/cmd/gobind@latest
#     gomobile init
#
# Output: ios/WiiUCore/Frameworks/Mobile.xcframework (git-ignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${IOS_DIR}/.." && pwd)"

if ! command -v gomobile >/dev/null 2>&1; then
    echo "error: gomobile not found on PATH" >&2
    echo "       install it with: go install golang.org/x/mobile/cmd/gomobile@latest" >&2
    exit 1
fi

OUTPUT="${IOS_DIR}/WiiUCore/Frameworks/Mobile.xcframework"
mkdir -p "$(dirname "${OUTPUT}")"
rm -rf "${OUTPUT}"

# Run from the repo root so the wrapper package resolves inside the root module.
cd "${REPO_DIR}"

gomobile bind \
    -target=ios \
    -iosversion=16.0 \
    -o "${OUTPUT}" \
    github.com/Xpl0itU/WiiUDownloader/ios/mobile

echo "Wrote ${OUTPUT}"
