#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift_bin="$(xcrun --find swift)"
cache_dir="$repo_root/.build/test-caches"
mkdir -p "$cache_dir"

# Command Line Tools bundle Testing outside Swift's default framework search path.
# Xcode's corresponding framework lives under the macOS platform directory.
swift_args=(
    test --package-path "$repo_root"
    --disable-sandbox --disable-xctest
    --cache-path "$cache_dir/packages"
    --config-path "$cache_dir/config"
    --security-path "$cache_dir/security"
)
for framework_dir in \
    "$developer_dir/Library/Developer/Frameworks" \
    "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
    if [[ -d "$framework_dir/Testing.framework" ]]; then
        swift_args+=(
            -Xswiftc -F -Xswiftc "$framework_dir"
            -Xlinker -F -Xlinker "$framework_dir"
            -Xlinker -rpath -Xlinker "$framework_dir"
        )
        runtime_dir="$framework_dir/../usr/lib"
        if [[ -d "$runtime_dir" ]]; then
            swift_args+=(-Xlinker -rpath -Xlinker "$runtime_dir")
        fi
        break
    fi
done

export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swift"
exec "$swift_bin" "${swift_args[@]}" "$@"
