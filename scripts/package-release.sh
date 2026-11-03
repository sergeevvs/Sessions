#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$repo_root/scripts/build-app.sh" --universal
release_dir="$repo_root/build/release"
mkdir -p "$release_dir"
package_dir="$(mktemp -d "$repo_root/build/package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir "$package_dir/Sessions"
/usr/bin/ditto "$repo_root/build/Sessions.app" "$package_dir/Sessions/Sessions.app"
for architecture in arm64 x86_64; do
    xcrun swiftc -O -target "$architecture-apple-macosx26.0" \
        -module-cache-path "$repo_root/build/cache/installer-modules" \
        "$repo_root/scripts/install-app-helper.swift" -o "$package_dir/installer-$architecture"
done
xcrun lipo -create "$package_dir/installer-arm64" "$package_dir/installer-x86_64" \
    -output "$package_dir/Sessions/SessionsInstaller"
codesign --force --sign - "$package_dir/Sessions/SessionsInstaller"
codesign --verify --deep --strict "$package_dir/Sessions/Sessions.app"
codesign --verify --strict "$package_dir/Sessions/SessionsInstaller"
archive="$release_dir/Sessions-macOS-universal.zip"
rm -f "$archive"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_dir/Sessions" "$archive"
(cd "$release_dir" && shasum -a 256 Sessions-macOS-universal.zip > SHA256SUMS)
printf 'Packaged %s\n' "$archive"
