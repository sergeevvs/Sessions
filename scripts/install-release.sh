#!/bin/bash
set -euo pipefail
repository=sergeevvs/Sessions
destination="$HOME/Applications"
launch=true
usage() {
    cat <<'HELP'
Usage: bash install-release.sh [--destination DIRECTORY] [--no-launch]

Download the latest private GitHub release and install Sessions.
Requires macOS 26+ and an authenticated GitHub CLI (gh). No Xcode needed.
Defaults to ~/Applications/Sessions.app and launches the app.
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { printf 'Missing destination directory.\n' >&2; exit 2; }
            destination="$2"; shift 2 ;;
        --no-launch) launch=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { printf 'Sessions requires macOS.\n' >&2; exit 1; }
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 26 ]] || { printf 'Sessions requires macOS 26+.\n' >&2; exit 1; }
command -v gh > /dev/null || { printf 'Install GitHub CLI (gh), then run gh auth login.\n' >&2; exit 1; }
gh auth status --hostname github.com > /dev/null 2>&1 || { printf 'Run gh auth login with access to %s first.\n' "$repository" >&2; exit 1; }
mkdir -p "$destination"
destination="$(cd "$destination" && pwd -P)"
target="$destination/Sessions.app"
validate_target() {
    [[ ! -L "$target" ]] || { printf 'Refusing to replace symbolic link: %s\n' "$target" >&2; exit 1; }
    if [[ -e "$target" ]]; then
        existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$existing_id" == local.pomodoro.menubar ]] || { printf 'Another app exists at %s\n' "$target" >&2; exit 1; }
    fi
}
validate_target
work_dir="$(mktemp -d "$destination/.sessions-install.XXXXXX")"
new_installed=false
install_complete=false
cleanup() {
    local result=$?
    if ! $install_complete; then
        if $new_installed && ! rm -rf "$target"; then
            printf 'Rollback failed; previous bundle retained in %s\n' "$work_dir" >&2
            return "$result"
        fi
        if [[ -d "$work_dir/previous.app" ]] && ! mv "$work_dir/previous.app" "$target"; then
            printf 'Restore failed; previous bundle retained in %s\n' "$work_dir" >&2
            return "$result"
        fi
    fi
    rm -rf "$work_dir"
    return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work_dir/download"
tag="$(gh api "repos/$repository/releases/latest" --jq .tag_name)"
gh release download "$tag" --repo "$repository" --pattern Sessions-macOS-universal.zip \
    --pattern SHA256SUMS --dir "$work_dir/download"
(cd "$work_dir/download" && shasum -a 256 -c SHA256SUMS)
/usr/bin/ditto -x -k "$work_dir/download/Sessions-macOS-universal.zip" "$work_dir/unpacked"
payload="$work_dir/unpacked/Sessions"
codesign --verify --deep --strict "$payload/Sessions.app"
codesign --verify --strict "$payload/SessionsInstaller"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$payload/Sessions.app/Contents/Info.plist")" == local.pomodoro.menubar ]]
validate_target
mode=no-launch
if $launch; then mode=release; fi
"$payload/SessionsInstaller" "$target" "$payload/Sessions.app" "$mode" > "$work_dir/previous-paths"
if [[ -d "$target" ]]; then mv "$target" "$work_dir/previous.app"; fi
mv "$payload/Sessions.app" "$target"
new_installed=true
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
while IFS= read -r previous_path; do
    if [[ -n "$previous_path" && "$previous_path" != "$target" ]]; then
        "$lsregister" -u "$previous_path" > /dev/null 2>&1 || true
    fi
done < "$work_dir/previous-paths"
"$lsregister" -f "$target"
install_complete=true
printf 'Installed Sessions %s at %s\n' "$tag" "$target"
if $launch; then open "$target"; fi
