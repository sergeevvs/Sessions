#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bash "$repo_root/scripts/install-app.sh" --help > /dev/null 2>&1 || fail 'installer help must succeed'
[[ -d "$repo_root/build/Sessions.app" ]] || fail 'run bash scripts/build-app.sh first'

fixture="$(mktemp -d "${TMPDIR:-/tmp}/sessions-install-test.XXXXXX")"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup() {
    "$lsregister" -u "$fixture/Applications with spaces/Sessions.app" > /dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/repo/scripts"
cp "$repo_root/scripts/install-app.sh" "$repo_root/scripts/install-app-helper.swift" "$fixture/repo/scripts/"
export SESSIONS_TEST_APP="$repo_root/build/Sessions.app"
cat > "$fixture/repo/scripts/build-app.sh" <<'BUILD'
#!/bin/bash
set -euo pipefail
[[ "${SESSIONS_TEST_BUILD_FAIL:-0}" != 1 ]] || exit 42
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_root/build"
/usr/bin/ditto "$SESSIONS_TEST_APP" "$repo_root/build/Sessions.app"
BUILD
installer="$fixture/repo/scripts/install-app.sh"
destination="$fixture/Applications with spaces"

# Exercise actual copying, validation and registration; substitute only the build.
bash "$installer" --destination "$destination" --no-launch > "$fixture/install.log" 2>&1 || { cat "$fixture/install.log"; fail 'installation'; }
cmp "$SESSIONS_TEST_APP/Contents/MacOS/Pomodoro" "$destination/Sessions.app/Contents/MacOS/Pomodoro" || fail 'installed executable differs'
codesign --verify --deep --strict "$destination/Sessions.app" || fail 'installed signature'
printf 'PASS: installation into a path with spaces\n'

touch "$destination/Sessions.app/obsolete-resource"
bash "$installer" --destination "$destination" --no-launch > "$fixture/update.log" 2>&1 || { cat "$fixture/update.log"; fail 'update'; }
[[ ! -e "$destination/Sessions.app/obsolete-resource" ]] || fail 'update left stale bundle contents'
printf 'PASS: update replaces the complete bundle\n'

touch "$destination/Sessions.app/preserve-on-failure"
if SESSIONS_TEST_BUILD_FAIL=1 bash "$installer" --destination "$destination" --no-launch > "$fixture/failure.log" 2>&1; then
    fail 'failed build reported success'
fi
[[ -f "$destination/Sessions.app/preserve-on-failure" ]] || fail 'failed build modified the installed app'
printf 'PASS: build failure preserves existing installation\n'

mkdir -p "$fixture/unrelated/Sessions.app/Contents"
cp "$repo_root/Resources/Info.plist" "$fixture/unrelated/Sessions.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.unrelated' "$fixture/unrelated/Sessions.app/Contents/Info.plist"
if bash "$installer" --destination "$fixture/unrelated" --no-launch > "$fixture/unrelated.log" 2>&1; then
    fail 'overwrote an unrelated app'
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$fixture/unrelated/Sessions.app/Contents/Info.plist")" == com.example.unrelated ]] || fail 'unrelated app changed'
printf 'PASS: unrelated app preserved\n'

mkdir "$fixture/linked"
ln -s "$destination/Sessions.app" "$fixture/linked/Sessions.app"
if bash "$installer" --destination "$fixture/linked" --no-launch > "$fixture/symlink.log" 2>&1; then
    fail 'accepted a symbolic link as the app target'
fi
[[ -L "$fixture/linked/Sessions.app" && -d "$destination/Sessions.app" ]] || fail 'symlink target changed'
if bash "$installer" --unknown-option > /dev/null 2>&1; then fail 'accepted an unknown option'; fi
printf 'PASS: symlink and invalid arguments rejected\n'
