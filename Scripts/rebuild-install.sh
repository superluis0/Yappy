#!/usr/bin/env bash
#
# rebuild-install.sh — rebuild Yappy in the correct environment and install it.
#
# Guarantees that what's running on this Mac is the code you just changed,
# without losing Microphone/Accessibility permissions:
#
#   • Release config — the Debug config uses bundle id com.yappy.app.debug,
#     which is a SEPARATE app and would not update the real Yappy.
#   • Signed with the SAME Developer ID as public releases. macOS TCC keys
#     Microphone/Accessibility grants on the code-signing identity, so signing dev
#     builds with the release identity means grants survive across rebuilds AND
#     across Sparkle updates (no re-prompting when you switch between a dev build
#     and a published release). The script FAILS CLOSED: if the build isn't signed
#     by that identity, it refuses to install rather than reset your permissions.
#   • Built to a temp dir under /tmp — building under the iCloud-synced Desktop
#     breaks codesign.
#   • Quits the old instance, replaces /Applications/Yappy.app, de-registers the
#     temp copy from LaunchServices, relaunches, and verifies the fresh binary
#     is the one now running.
#
# Usage:
#   Scripts/rebuild-install.sh              # build + install + relaunch (default)
#   Scripts/rebuild-install.sh --test       # run the unit suite first; abort if it fails
#   Scripts/rebuild-install.sh --build-only # build + verify signature only; don't install
#   Scripts/rebuild-install.sh --help
#
set -euo pipefail

SCHEME="Yappy"
TEAM_ID="JY8DZXQ5P2"
# Same Developer ID the release pipeline uses — so dev builds and releases share
# one designated requirement and TCC permissions persist across both.
EXPECTED_IDENTITY="Developer ID Application: Luis Landeros (JY8DZXQ5P2)"
APP_DEST="/Applications/Yappy.app"
BUILD_DIR="$(mktemp -d /tmp/yappy-rel.XXXXXX)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Colors only when attached to a terminal.
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_RED=""; C_OFF=""
fi
log() { printf '%s▸%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()  { printf '%s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
die() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

BUILD_ONLY=0
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --test) RUN_TESTS=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $arg (try --help)" ;;
  esac
done

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
[[ -d "Yappy.xcodeproj" ]] || die "Run from the Yappy repo (Yappy.xcodeproj not found)."
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$EXPECTED_IDENTITY" \
  || die "Signing identity not found: '$EXPECTED_IDENTITY'. Import the Developer ID certificate into your login keychain."

if [[ "$RUN_TESTS" == 1 ]]; then
  log "Running unit tests…"
  xcodebuild test -project Yappy.xcodeproj -scheme "$SCHEME" \
    -destination 'platform=macOS' -configuration Debug -quiet \
    || die "Tests failed — not building or installing."
  ok "Tests passed."
fi

# Stamp the same git-derived build number the release pipeline uses
# (Scripts/release-dmg.sh). Without this a dev build keeps the static
# CURRENT_PROJECT_VERSION=1, which is lower than the published appcast's build
# number — so the in-app updater would nag forever that "an update" (really just
# the release of the same code) is available. Matching the release build number
# keeps dev builds at-or-ahead of the feed.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

log "Building Release (build $BUILD_NUMBER) to $BUILD_DIR …"
# Sign with the release Developer ID + Hardened Runtime so the designated
# requirement matches published releases (keeps TCC grants). No --timestamp /
# notarization needed for a locally-built, non-quarantined app.
xcodebuild -project Yappy.xcodeproj -scheme "$SCHEME" \
  -configuration Release -derivedDataPath "$BUILD_DIR" -quiet build \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$EXPECTED_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  || die "Build failed."
# --timestamp (secure timestamp from Apple's server, needs network) instead of
# --timestamp=none: an untimestamped signature is another dev/release difference
# suspected of making TCC pin the Accessibility grant to the per-build hash
# instead of the stable Developer ID requirement. Release/notarized builds have
# always kept their grants; timestamping is the cheap half of that gap.

# TCC-identity guard: Xcode injects the get-task-allow (debug) entitlement into
# non-distribution builds unless CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO above.
# With get-task-allow present, macOS keys the app's Accessibility grant to the
# PER-BUILD binary hash instead of the stable Developer ID — so every rebuild
# showed up as a brand-new "Yappy" in System Settings and the grant never stuck.
# Fail closed if it ever sneaks back in.
if codesign -d --entitlements - "$BUILD_DIR/Build/Products/Release/Yappy.app" 2>/dev/null \
    | grep -q "get-task-allow"; then
  die "Built app contains get-task-allow — TCC grants would not persist. Aborting."
fi

APP_SRC="$BUILD_DIR/Build/Products/Release/Yappy.app"
[[ -d "$APP_SRC" ]] || die "Built app not found at $APP_SRC"

# Fail closed: only install a build signed by the local identity, so we never
# reset the app's TCC permissions with an ad-hoc signature.
SIGINFO="$(codesign -dvv "$APP_SRC" 2>&1 || true)"
AUTH="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=//p' | head -1)"
[[ "$AUTH" == "$EXPECTED_IDENTITY" ]] \
  || die "Built app is signed by '${AUTH:-nothing}', expected '$EXPECTED_IDENTITY'. Refusing to install (it would reset Microphone/Accessibility permissions)."
ok "Built and signed by '$EXPECTED_IDENTITY'."

if [[ "$BUILD_ONLY" == 1 ]]; then
  ok "Build-only: signature verified, not installing."
  exit 0
fi

log "Quitting any running Yappy…"
osascript -e 'tell application "Yappy" to quit' 2>/dev/null || true
sleep 2
pkill -f "$APP_DEST/Contents/MacOS/Yappy" 2>/dev/null || true
sleep 1

log "Installing to $APP_DEST …"
# Update the bundle IN PLACE — never `rm -rf` it. A full delete makes the app
# momentarily absent from disk, and macOS drops its Accessibility (and Input
# Monitoring) TCC grant when the granted app disappears — so every rebuild came
# up untrusted and re-prompted. rsync --delete overwrites the destination to
# match the freshly-signed source exactly (pruning any files removed across
# builds) while the bundle keeps its on-disk identity, so the grant persists.
# The app was already quit + pkilled above, so nothing is overwriting a live
# process. On first install the dest doesn't exist yet; rsync creates it.
rsync -a --delete "$APP_SRC/" "$APP_DEST/"
# Clear any extended-attribute detritus that can fail Gatekeeper/codesign checks.
xattr -cr "$APP_DEST" 2>/dev/null || true

# Keep exactly one com.yappy.app registered with LaunchServices: drop the temp
# copy, force-register the installed one. Duplicate registrations break TCC.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$APP_SRC" 2>/dev/null || true
  "$LSREGISTER" -f "$APP_DEST" 2>/dev/null || true
fi

INSTALLED_AUTH="$(codesign -dvv "$APP_DEST" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
[[ "$INSTALLED_AUTH" == "$EXPECTED_IDENTITY" ]] \
  || die "Installed app signature unexpected: '${INSTALLED_AUTH:-nothing}'."

log "Relaunching…"
open "$APP_DEST"
sleep 3
pgrep -f "$APP_DEST/Contents/MacOS/Yappy" >/dev/null || die "App did not relaunch."

COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo
ok "Yappy rebuilt and running."
printf '   commit:    %s\n' "$COMMIT"
printf '   signed by: %s\n' "$INSTALLED_AUTH"
printf '   installed: %s\n' "$APP_DEST"
printf '   Permissions preserved (same bundle id + signing identity).\n'
