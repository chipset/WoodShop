#!/bin/zsh
# Build and run the native XCTest suite, including on a CLT-only active toolchain.
set -e
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
if ! swift --version >/dev/null 2>&1 && [[ -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
sdk_options=()
if [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_options=(--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
TEST_FRAMEWORKS=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
TEST_LIBRARIES=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
TEST_RUNNER=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest
swift build --build-tests --build-system native "${sdk_options[@]}" --scratch-path "$PWD/.build/native" --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "$@" \
  -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xswiftc -I -Xswiftc "$TEST_LIBRARIES" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_LIBRARIES" -Xlinker -L -Xlinker "$TEST_LIBRARIES"
DYLD_FRAMEWORK_PATH="$TEST_FRAMEWORKS" DYLD_LIBRARY_PATH="$TEST_LIBRARIES" "$TEST_RUNNER" "$PWD/.build/native/debug/WoodShopPackageTests.xctest"
