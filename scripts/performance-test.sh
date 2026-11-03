#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$repo_root"
output="$repo_root/build/performance/$(date +%Y%m%d-%H%M%S)"
seconds=15
rounds=2
build_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root|--output|--seconds|--rounds)
            [[ $# -ge 2 ]] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            case "$1" in
                --source-root) source_root="$2" ;;
                --output) output="$2" ;;
                --seconds) seconds="$2" ;;
                --rounds) rounds="$2" ;;
            esac
            shift 2 ;;
        --build-only) build_only=true; shift ;;
        *) printf 'Usage: bash scripts/performance-test.sh [--seconds 15] [--rounds 2] [--output DIR] [--source-root DIR] [--build-only]\n' >&2; exit 2 ;;
    esac
done
[[ -f "$source_root/Package.swift" ]] || { printf 'Source root must contain Package.swift\n' >&2; exit 2; }
mkdir -p "$output"
output="$(cd "$output" && pwd)"
[[ ! -e "$output/source" ]] || { printf 'Choose a fresh output directory: %s\n' "$output" >&2; exit 2; }
cache_dir="$repo_root/build/performance-cache"
mkdir -p "$cache_dir"
export CLANG_MODULE_CACHE_PATH="$cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_dir/swift"

# Freeze the exact app sources under test. The probe does not compile AppMain,
# acquire the user's instance lock, or read their standard defaults domain.
mkdir -p "$output/source"
cp "$source_root/Package.swift" "$output/source/Package.swift"
cp -R "$source_root/Sources" "$output/source/Sources"
cp -R "$source_root/Tests" "$output/source/Tests"
cp "$repo_root/scripts/performance/PerformanceProbe.swift" "$output/PerformanceProbe.swift"
# Keep the diagnostic window visible while the user works in another app. This
# helper exists only in the copied test source, next to the private method it
# calls; the repository's production controller remains unchanged.
cat >> "$output/source/Sources/PomodoroApp/StatusBarController.swift" <<'SWIFT'

extension StatusBarController {
    func suspendDismissalForPerformanceProbe() { stopDismissalObservers() }
}
SWIFT
(
    cd "$output"
    rg --files source -g '*.swift' | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done
    shasum -a 256 PerformanceProbe.swift
) > "$output/source-manifest.sha256"
swift_args=(--package-path "$output/source" --scratch-path "$cache_dir/swiftpm"
    --configuration release --disable-sandbox --cache-path "$cache_dir/packages"
    --config-path "$cache_dir/config" --security-path "$cache_dir/security")
if ! xcrun swift build "${swift_args[@]}" --product Pomodoro > "$output/build.log" 2>&1; then
    cat "$output/build.log" >&2
    exit 1
fi
bin_dir="$(xcrun swift build "${swift_args[@]}" --show-bin-path)"
app_sources=()
while IFS= read -r file; do
    [[ "${file##*/}" == AppMain.swift ]] || app_sources+=("$file")
done < <(rg --files "$output/source/Sources/PomodoroApp" -g '*.swift' | LC_ALL=C sort)
core_objects=("$bin_dir"/PomodoroCore.build/*.swift.o)
if ! xcrun swiftc -swift-version 6 -parse-as-library -O -g \
    -target "$(uname -m)-apple-macos26.0" -module-name SessionsPerformanceProbe \
    -module-cache-path "$cache_dir/clang" -I "$bin_dir/Modules" \
    -o "$output/PerformanceProbe" "$output/PerformanceProbe.swift" \
    "${app_sources[@]}" "${core_objects[@]}" >> "$output/build.log" 2>&1; then
    cat "$output/build.log" >&2
    exit 1
fi
printf 'Probe: %s\nResults: %s\n' "$output/PerformanceProbe" "$output/results.json"
if ! $build_only; then
    "$output/PerformanceProbe" --seconds "$seconds" --rounds "$rounds" --output "$output/results.json" | tee "$output/run.log"
fi
