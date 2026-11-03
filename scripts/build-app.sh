#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
universal=false
if [[ "${1:-}" == --universal && $# -eq 1 ]]; then
    universal=true
elif [[ $# -ne 0 ]]; then
    printf 'Usage: bash scripts/build-app.sh [--universal]\n' >&2
    exit 2
fi
swift_bin="$(xcrun --find swift)"
cache_dir="$repo_root/build/cache"
app_dir="$repo_root/build/Sessions.app"
mkdir -p "$cache_dir"

export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swift"
swift_args=(
    --package-path "$repo_root"
    --configuration release
    --disable-sandbox
    --cache-path "$cache_dir/packages"
    --config-path "$cache_dir/config"
    --security-path "$cache_dir/security"
)
mkdir -p "$app_dir/Contents/MacOS"
if $universal; then
    # Separate SwiftPM builds also work with Command Line Tools alone; the
    # multi-architecture SwiftPM build requires XCBuild from full Xcode.
    binaries=()
    for architecture in arm64 x86_64; do
        "$swift_bin" build "${swift_args[@]}" --arch "$architecture" --product Pomodoro
        bin_path="$("$swift_bin" build "${swift_args[@]}" --arch "$architecture" --show-bin-path)"
        binaries+=("$bin_path/Pomodoro")
    done
    xcrun lipo -create "${binaries[@]}" -output "$app_dir/Contents/MacOS/Pomodoro"
else
    "$swift_bin" build "${swift_args[@]}" --product Pomodoro
    bin_path="$("$swift_bin" build "${swift_args[@]}" --show-bin-path)"
    cp "$bin_path/Pomodoro" "$app_dir/Contents/MacOS/Pomodoro"
fi
cp "$repo_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"

# Retire the pre-rename generated bundle: notification routing uses bundle IDs,
# so keeping two runnable builds with the same ID can launch the wrong copy.
legacy_app="$repo_root/build/Pomodoro.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -d "$legacy_app" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app/Contents/Info.plist")" == "local.pomodoro.menubar" ]]; then
    legacy_archive="$repo_root/build/Pomodoro-legacy-$(date +%Y%m%d%H%M%S).zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$legacy_app" "$legacy_archive"
    "$lsregister" -u "$legacy_app"
    rm -rf "$legacy_app"
fi
"$lsregister" -f "$app_dir"
printf 'Built %s\n' "$app_dir"
