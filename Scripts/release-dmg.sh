#!/usr/bin/env bash
#
# release-dmg.sh — build a notarized, stapled Yappy.dmg for distribution
# OUTSIDE the App Store. The result installs with zero Gatekeeper friction:
# download → drag Yappy to Applications → double-click → it opens.
#
# Pipeline:
#   1. Archive Release, then export the app signed with "Developer ID
#      Application" (Hardened Runtime + secure timestamp; deep-signs the
#      embedded FluidAudio libraries).
#   2. Notarize the app with Apple's notary service and STAPLE the ticket, so
#      it launches even offline and even after being copied out of the DMG.
#   3. Package a compressed DMG (Yappy.app + an /Applications symlink), sign
#      it, then notarize and staple the DMG too.
#   4. Optionally publish the DMG to a GitHub Release (--publish <tag>).
#
# This does NOT touch the local-dev flow: rebuild-install.sh keeps using the
# "Yappy Local Signing" cert. Release signing happens only here, in export.
#
# ── One-time setup (only you can do this; it ties to your Apple account) ──
#   Store notarization credentials in the keychain under the profile name
#   "YappyNotary" (override with YAPPY_NOTARY_PROFILE=...). Either method works
#   identically with this script:
#
#   A) App-specific password — instant, no approval gate (recommended). Create
#      one at appleid.apple.com -> Sign-In and Security -> App-Specific
#      Passwords, then:
#
#        xcrun notarytool store-credentials "YappyNotary" \
#          --apple-id "you@example.com" \
#          --team-id "JY8DZXQ5P2" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#
#   B) App Store Connect API key — from App Store Connect -> Users and Access
#      -> Integrations -> App Store Connect API ("Developer" role is enough).
#      Download the .p8 (one download only); note its Key ID and Issuer ID:
#
#        xcrun notarytool store-credentials "YappyNotary" \
#          --key /path/to/AuthKey_XXXXXXXX.p8 \
#          --key-id XXXXXXXX \
#          --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# Usage:
#   Scripts/release-dmg.sh                  # build notarized DMG into ./dist
#   Scripts/release-dmg.sh --version 2.1    # override the marketing version
#   Scripts/release-dmg.sh --publish v2.1   # also upload to a GitHub Release
#   Scripts/release-dmg.sh --sign-only      # archive + Developer ID sign only
#                                           #   (verify signing; no notarization,
#                                           #    no Apple credentials required)
#   Scripts/release-dmg.sh --help
#
set -euo pipefail

SCHEME="Yappy"
TEAM_ID="JY8DZXQ5P2"
DEV_ID="Developer ID Application: Luis Landeros (JY8DZXQ5P2)"
NOTARY_PROFILE="${YAPPY_NOTARY_PROFILE:-YappyNotary}"
VOL_NAME="Yappy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DIST_DIR="$REPO_ROOT/dist"
# Build under /tmp: the repo lives on the iCloud-synced Desktop, which breaks
# codesign mid-flight. Only the finished, stapled DMG is moved into ./dist.
BUILD_DIR="$(mktemp -d /tmp/yappy-dist.XXXXXX)"

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

# Submit an artifact to the notary service, wait, and fail loudly (dumping the
# notary log) if it isn't Accepted.
notarize() {
  local artifact="$1" out sid
  log "Notarizing $(basename "$artifact") (a few minutes)…"
  if ! out="$(xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; then
    printf '%s\n' "$out" >&2
    sid="$(printf '%s\n' "$out" | sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' | head -1)"
    [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Notarization failed. (Is the '$NOTARY_PROFILE' keychain profile set up? See --help.)"
  fi
  if ! printf '%s\n' "$out" | grep -q "status: Accepted"; then
    printf '%s\n' "$out" >&2
    sid="$(printf '%s\n' "$out" | sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' | head -1)"
    [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Notarization not Accepted for $(basename "$artifact"). See the log above."
  fi
}

# Build a DMG from a signed .app. Lays out a branded Finder window (background
# image + icon positions) with built-in tools only. Falls back to a plain
# drag-to-Applications DMG if the Finder layout can't be applied (e.g. Automation
# permission is denied) — cosmetics must never fail a release.
build_dmg() {
  local app="$1" out="$2"
  local bg="$REPO_ROOT/Scripts/dmg-assets/dmg-background.png"
  local layout="$REPO_ROOT/Scripts/dmg-assets/layout-dmg.applescript"
  local rw="$BUILD_DIR/rw.dmg"
  rm -f "$rw" "$out"

  if [[ -f "$bg" && -f "$layout" ]]; then
    local mb=$(( $(du -sm "$app" | cut -f1) + 50 ))   # app size + slack for .DS_Store/background
    if hdiutil create -size "${mb}m" -fs HFS+ -volname "$VOL_NAME" -ov "$rw" >/dev/null 2>&1; then
      # Mount at the default /Volumes location — Finder can only script volumes
      # there. Read back the real mount point (it may be "Yappy 1" on collision).
      local attach_out mount vol
      attach_out="$(hdiutil attach "$rw" -nobrowse -noautoopen -noverify 2>/dev/null)"
      mount="$(printf '%s\n' "$attach_out" | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)"
      if [[ -n "$mount" && -d "$mount" ]]; then
        vol="$(basename "$mount")"
        cp -R "$app" "$mount/"
        ln -s /Applications "$mount/Applications"
        mkdir -p "$mount/.background"
        cp "$bg" "$mount/.background/dmg-background.png"
        if osascript "$layout" "$vol" >/dev/null 2>&1; then
          ok "Applied branded DMG window."
        else
          log "Note: branded layout skipped (grant your terminal 'Automation → Finder' in System Settings → Privacy & Security) — plain window this time."
        fi
        sync
        hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach "$mount" -force >/dev/null 2>&1 || true
        if hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$out" >/dev/null 2>&1; then
          rm -f "$rw"; return 0
        fi
      fi
    fi
    log "Note: branded DMG build failed — falling back to a plain DMG."
    rm -f "$rw" "$out"
  fi

  # Plain fallback: simple drag-to-Applications window.
  local staging="$BUILD_DIR/dmg-plain"
  rm -rf "$staging"; mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "$VOL_NAME" -srcfolder "$staging" -ov -format UDZO "$out" >/dev/null \
    || die "hdiutil create failed."
}

VERSION=""
PUBLISH_TAG=""
SIGN_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --publish) PUBLISH_TAG="${2:-}"; shift 2 ;;
    --sign-only) SIGN_ONLY=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
[[ -d "Yappy.xcodeproj" ]] || die "Run from the Yappy repo (Yappy.xcodeproj not found)."
security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEV_ID" \
  || die "Signing identity not in keychain: $DEV_ID"
ok "Found signing identity: $DEV_ID"

# Unique, monotonic build number from git history.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# ── 1. Archive ──────────────────────────────────────────────────────────
ARCHIVE="$BUILD_DIR/Yappy.xcarchive"
log "Archiving Release (build $BUILD_NUMBER)…"
XCARGS=(
  -project Yappy.xcodeproj -scheme "$SCHEME" -configuration Release
  -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR/dd"
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
[[ -n "$VERSION" ]] && XCARGS+=( MARKETING_VERSION="$VERSION" )
xcodebuild archive "${XCARGS[@]}" -quiet || die "Archive failed."
ok "Archived."

# ── 2. Export, signed with Developer ID ─────────────────────────────────
# exportArchive re-signs the app + nested code with the Developer ID cert,
# Hardened Runtime, and a secure timestamp. No provisioning profile is needed
# (the app uses no profile-gated capabilities).
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

EXPORT_DIR="$BUILD_DIR/export"
log "Exporting signed app…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -quiet \
  || die "Export failed."

APP="$EXPORT_DIR/Yappy.app"
[[ -d "$APP" ]] || die "Exported app not found at $APP"

SIGINFO="$(codesign -dvv "$APP" 2>&1 || true)"
ACTUAL_AUTH="$(printf '%s\n' "$SIGINFO" | sed -n 's/^Authority=//p' | head -1)"
if [[ "$ACTUAL_AUTH" != "$DEV_ID" ]]; then
  printf '%s\n' "$SIGINFO" >&2
  die "Exported app signed by '${ACTUAL_AUTH:-nothing}', expected '$DEV_ID'."
fi
printf '%s\n' "$SIGINFO" | grep -q "runtime" \
  || die "Exported app is missing the Hardened Runtime flag."
codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign --verify failed."
ok "Signed with Developer ID + Hardened Runtime."

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0")"

if [[ "$SIGN_ONLY" == 1 ]]; then
  echo
  ok "Sign-only: archive + Developer ID signing verified (version $VERSION, build $BUILD_NUMBER)."
  log "Skipped notarization, DMG, and publishing. Run without --sign-only for the full release."
  exit 0
fi

# ── 3. Notarize + staple the app ────────────────────────────────────────
APP_ZIP="$BUILD_DIR/Yappy-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP"
xcrun stapler staple "$APP" || die "Stapling the app failed."
ok "App notarized and stapled."

# ── 4. Build, sign, notarize, staple the DMG ────────────────────────────
DMG_TMP="$BUILD_DIR/Yappy-$VERSION.dmg"
log "Building DMG…"
build_dmg "$APP" "$DMG_TMP"
codesign --sign "$DEV_ID" --timestamp "$DMG_TMP" || die "Signing the DMG failed."
notarize "$DMG_TMP"
xcrun stapler staple "$DMG_TMP" || die "Stapling the DMG failed."
ok "DMG notarized and stapled."

if spctl -a -vvv -t open --context context:primary-signature "$DMG_TMP" 2>&1 | grep -q "accepted"; then
  ok "Gatekeeper accepts the DMG."
else
  log "Note: spctl check was inconclusive (informational only)."
fi

mkdir -p "$DIST_DIR"
OUT_DMG="$DIST_DIR/Yappy-$VERSION.dmg"
rm -f "$OUT_DMG"
mv "$DMG_TMP" "$OUT_DMG"

# ── 5. Optional: publish to a GitHub Release ────────────────────────────
if [[ -n "$PUBLISH_TAG" ]]; then
  command -v gh >/dev/null || die "gh CLI not found — install it or omit --publish."
  log "Publishing to GitHub Release $PUBLISH_TAG…"
  if gh release view "$PUBLISH_TAG" >/dev/null 2>&1; then
    gh release upload "$PUBLISH_TAG" "$OUT_DMG" --clobber
  else
    gh release create "$PUBLISH_TAG" "$OUT_DMG" --title "Yappy $VERSION" \
      --notes "Download the DMG, drag Yappy to Applications, and open it. On first launch, grant Microphone and Accessibility in System Settings → Privacy & Security."
  fi
  ok "Published to GitHub Release $PUBLISH_TAG."
fi

echo
ok "Release ready."
printf '   version:  %s (build %s)\n' "$VERSION" "$BUILD_NUMBER"
printf '   dmg:      %s\n' "$OUT_DMG"
printf '   signed:   %s\n' "$DEV_ID"
printf '   notarized + stapled (app and dmg).\n'
