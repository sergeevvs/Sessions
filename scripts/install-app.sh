#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$HOME/Applications"
launch=true
usage() {
    cat <<'HELP'
Usage: bash scripts/install-app.sh [--destination DIRECTORY] [--no-launch]

Build and install Sessions (macOS 26+, Xcode or Command Line Tools with Swift 6.2+).
Default destination: ~/Applications/Sessions.app. Launches the installed app.

  --destination DIRECTORY  Install in another Applications directory
  --no-launch              Install without launching or stopping other copies
  -h, --help               Show this help
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { printf 'Missing destination directory.\n' >&2; exit 2; }
            destination="$2"; shift 2 ;;
        --no-launch) launch=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || { printf 'Sessions requires macOS.\n' >&2; exit 1; }
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 26 ]] || { printf 'Sessions requires macOS 26 or later.\n' >&2; exit 1; }
xcrun --find swift > /dev/null
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
target="$destination/Sessions.app"
built_app="$repo_root/build/Sessions.app"
[[ "$target" != "$built_app" ]] || { printf 'Choose a destination outside the build directory.\n' >&2; exit 1; }
bundle_id="local.pomodoro.menubar"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

validate_target() {
    if [[ -L "$target" ]]; then
        printf 'Refusing to replace a symbolic link: %s\n' "$target" >&2; exit 1
    fi
    if [[ -e "$target" ]]; then
        existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$existing_id" == "$bundle_id" ]] || { printf 'Another app already exists at %s\n' "$target" >&2; exit 1; }
    fi
}
validate_target
bash "$repo_root/scripts/build-app.sh"

work_dir="$(mktemp -d "$destination/.sessions-install.XXXXXX")"
new_installed=false
cleanup() {
    local result=$?
    if [[ $result -ne 0 ]]; then
        if $new_installed && ! rm -rf "$target"; then
            printf 'Could not roll back. Previous bundle retained in %s\n' "$work_dir" >&2
            return "$result"
        fi
        if [[ -d "$work_dir/previous.app" ]]; then
            if ! mv "$work_dir/previous.app" "$target"; then
                printf 'Could not restore previous bundle. Retained in %s\n' "$work_dir" >&2
                return "$result"
            fi
        fi
    fi
    rm -rf "$work_dir"
    return "$result"
}
trap cleanup EXIT
/usr/bin/ditto "$built_app" "$work_dir/new.app"
codesign --verify --deep --strict "$work_dir/new.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$work_dir/new.app/Contents/Info.plist")" == "$bundle_id" ]]
validate_target

# Quit only the destination copy; when launching, also quit the project's build
# so the single-instance guard cannot redirect the launch to the old process.
mode=no-launch
if $launch; then mode=launch; fi
xcrun swift -module-cache-path "$repo_root/build/cache/installer-modules" \
    "$repo_root/scripts/install-app-helper.swift" "$target" "$built_app" "$mode"
if [[ -d "$target" ]]; then mv "$target" "$work_dir/previous.app"; fi
mv "$work_dir/new.app" "$target"
new_installed=true
"$lsregister" -f "$target"
# Prefer the installed bundle when opening notifications or login items.
"$lsregister" -u "$built_app" > /dev/null 2>&1 || true
printf 'Installed %s\n' "$target"

# Installation has succeeded; a launch failure should not undo the installation.
trap - EXIT
rm -rf "$work_dir"
if $launch; then open "$target"; fi
