#!/usr/bin/env bash
set -e

zig build

rm -rf Swap/Swap.xcframework
cp -r zig-out/Swap.xcframework Swap/Swap.xcframework

pushd Swap
xcode-build-server config -scheme Swap -project Swap.xcodeproj
if [ -n "$DEVELOPMENT_TEAM" ]; then
    xcodebuild -configuration Release DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
else
    xcodebuild -configuration Release
fi
popd
