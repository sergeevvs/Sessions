#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bash "$repo_root/install.sh" --help > /dev/null 2>&1 || fail 'release installer help must succeed'
[[ -f "$repo_root/build/release/Sessions-macOS-universal.zip" ]] || fail 'run bash scripts/package-release.sh first'
fixture="$(mktemp -d "${TMPDIR:-/tmp}/sessions-release-test.XXXXXX")"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup() {
    "$lsregister" -u "$fixture/Applications with spaces/Sessions.app" > /dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/bin"
export SESSIONS_TEST_ASSETS="$repo_root/build/release"
export SESSIONS_TEST_DOWNLOAD_PATH="$fixture/download-path"
# Only the GitHub network boundary is substituted. Use the real release archive,
# native installer helper, code signature checks, file replacement and cleanup.
cat > "$fixture/bin/curl" <<'CURL'
#!/bin/bash
set -euo pipefail
head_request=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --head) head_request=true; shift ;;
        --output) download_file="$2"; shift 2 ;;
        --write-out) shift 2 ;;
        https://*) download_url="$1"; shift ;;
        *) shift ;;
    esac
done
if $head_request; then
    printf 'https://github.com/sergeevvs/Sessions/releases/tag/v1.0.0'; exit 0
fi
download_dir="$(dirname "$download_file")"
printf '%s\n' "$download_dir" > "$SESSIONS_TEST_DOWNLOAD_PATH"
[[ "${SESSIONS_TEST_DOWNLOAD_FAIL:-0}" != 1 ]] || exit 41
case "$download_url" in
    https://github.com/sergeevvs/Sessions/releases/download/v1.0.0/Sessions-macOS-universal.zip)
        cp "$SESSIONS_TEST_ASSETS/Sessions-macOS-universal.zip" "$download_file"
        if [[ "${SESSIONS_TEST_CORRUPT:-0}" == 1 ]]; then printf 'corrupted' >> "$download_file"; fi ;;
    https://github.com/sergeevvs/Sessions/releases/download/v1.0.0/SHA256SUMS)
        cp "$SESSIONS_TEST_ASSETS/SHA256SUMS" "$download_file" ;;
    *) exit 90 ;;
esac
CURL
cat > "$fixture/bin/gh" <<'GH'
#!/bin/bash
printf 'GitHub CLI must not be used by the public installer.\n' >&2
exit 99
GH
chmod +x "$fixture/bin/curl" "$fixture/bin/gh"
destination="$fixture/Applications with spaces"
run_installer() {
    PATH="$fixture/bin:$PATH" bash "$repo_root/install.sh" --destination "$destination" --no-launch
}
run_installer > "$fixture/install.log" 2>&1 || { cat "$fixture/install.log"; fail 'release installation'; }
codesign --verify --deep --strict "$destination/Sessions.app" || fail 'installed signature'
[[ ! -e "$(cat "$SESSIONS_TEST_DOWNLOAD_PATH")" ]] || fail 'download directory not cleaned'
[[ ! -f "$destination/SessionsInstaller" ]] || fail 'helper leaked into Applications'
printf 'PASS: public release installs without GitHub CLI or compiler and cleans downloads\n'

touch "$destination/Sessions.app/obsolete-resource"
run_installer > "$fixture/update.log" 2>&1 || { cat "$fixture/update.log"; fail 'release update'; }
[[ ! -e "$destination/Sessions.app/obsolete-resource" ]] || fail 'stale resource survived update'
printf 'PASS: update replaces the entire installed bundle\n'

touch "$destination/Sessions.app/preserve-on-failure"
if SESSIONS_TEST_DOWNLOAD_FAIL=1 run_installer > "$fixture/download-failure.log" 2>&1; then fail 'download failure reported success'; fi
[[ -f "$destination/Sessions.app/preserve-on-failure" ]] || fail 'download failure changed installed app'
[[ ! -e "$(cat "$SESSIONS_TEST_DOWNLOAD_PATH")" ]] || fail 'failed download leaked temporary files'
printf 'PASS: failed download cleans up and preserves installation\n'

if SESSIONS_TEST_CORRUPT=1 run_installer > "$fixture/checksum-failure.log" 2>&1; then fail 'checksum mismatch accepted'; fi
[[ -f "$destination/Sessions.app/preserve-on-failure" ]] || fail 'checksum failure changed installed app'
[[ ! -e "$(cat "$SESSIONS_TEST_DOWNLOAD_PATH")" ]] || fail 'checksum failure leaked temporary files'
printf 'PASS: damaged download rejected without changing installation\n'
