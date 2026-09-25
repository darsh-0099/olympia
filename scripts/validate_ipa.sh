#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: $0 path/to/Olympia.ipa [expected.bundle.identifier]" >&2
}

fail() {
    echo "Olympia IPA validation failed: $*" >&2
    exit 1
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
    exit 64
fi

IPA_PATH=$1
EXPECTED_BUNDLE_ID=${2:-${SOLARH9_BUNDLE_ID:-com.olympia.app}}

[ -f "$IPA_PATH" ] || fail "file not found: $IPA_PATH"
command -v unzip >/dev/null 2>&1 || fail "the 'unzip' command is required"
command -v lipo >/dev/null 2>&1 || fail "the Apple 'lipo' command is required (install Xcode)"
[ -x /usr/libexec/PlistBuddy ] || fail "/usr/libexec/PlistBuddy is required"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/solarh9-ipa-validation.XXXXXX")
LIST_FILE="$WORK_DIR/archive-entries.txt"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

unzip -Z1 "$IPA_PATH" > "$LIST_FILE" || fail "could not read the ZIP directory"
[ -s "$LIST_FILE" ] || fail "archive is empty"

while IFS= read -r entry; do
    case "$entry" in
        /*|../*|*/../*|*/..|*\\*) fail "unsafe archive path: $entry" ;;
    esac
    case "$entry" in
        Payload|Payload/*) ;;
        *) fail "unexpected item outside the Payload directory: $entry" ;;
    esac
done < "$LIST_FILE"

APP_ROOT_COUNT=$(awk '
    {
        count = split($0, parts, "/")
        if (count >= 2 && parts[1] == "Payload" && parts[2] ~ /[.]app$/) {
            roots[parts[1] "/" parts[2]] = 1
        }
    }
    END { for (root in roots) total += 1; print total + 0 }
' "$LIST_FILE")
[ "$APP_ROOT_COUNT" -eq 1 ] || fail "archive must contain exactly one top-level .app; found $APP_ROOT_COUNT"
grep -q '^Payload/SolarH9\.app/Info\.plist$' "$LIST_FILE" || fail "expected Payload/SolarH9.app/Info.plist"

unzip -q "$IPA_PATH" -d "$WORK_DIR/extracted" || fail "could not extract the archive"
APP_PATH="$WORK_DIR/extracted/Payload/SolarH9.app"
INFO_PLIST="$APP_PATH/Info.plist"
[ -d "$APP_PATH" ] || fail "Payload/SolarH9.app is missing"
[ -f "$INFO_PLIST" ] || fail "the built app has no Info.plist"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null) || fail "Info.plist has no CFBundleIdentifier"
[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "bundle identifier is '$BUNDLE_ID'; expected '$EXPECTED_BUNDLE_ID'"

PACKAGE_TYPE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST" 2>/dev/null) || fail "Info.plist has no CFBundlePackageType"
[ "$PACKAGE_TYPE" = "APPL" ] || fail "CFBundlePackageType is '$PACKAGE_TYPE'; expected 'APPL'"

EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null) || fail "Info.plist has no CFBundleExecutable"
case "$EXECUTABLE_NAME" in
    ''|*/*|.|..) fail "unsafe CFBundleExecutable value: '$EXECUTABLE_NAME'" ;;
esac
EXECUTABLE_PATH="$APP_PATH/$EXECUTABLE_NAME"
[ -f "$EXECUTABLE_PATH" ] || fail "declared executable is missing: $EXECUTABLE_NAME"
[ -x "$EXECUTABLE_PATH" ] || fail "declared executable is not executable: $EXECUTABLE_NAME"

ARCHS=$(lipo -archs "$EXECUTABLE_PATH" 2>/dev/null) || fail "could not inspect executable architectures"
case " $ARCHS " in
    *' arm64 '*) ;;
    *) fail "device executable does not contain arm64 (found: $ARCHS)" ;;
esac

LIVE_ACTIVITY_PATH="$APP_PATH/PlugIns/SolarH9LiveActivity.appex"
LIVE_ACTIVITY_PLIST="$LIVE_ACTIVITY_PATH/Info.plist"
[ -d "$LIVE_ACTIVITY_PATH" ] || fail "the Dynamic Island Live Activity extension is missing"
[ -f "$LIVE_ACTIVITY_PLIST" ] || fail "the Live Activity extension has no Info.plist"
plutil -lint "$LIVE_ACTIVITY_PLIST" >/dev/null || fail "the Live Activity extension Info.plist is invalid"

EXTENSION_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LIVE_ACTIVITY_PLIST" 2>/dev/null) || fail "the Live Activity extension has no CFBundleIdentifier"
[ "$EXTENSION_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID.liveactivity" ] ||
    fail "Live Activity bundle identifier is '$EXTENSION_BUNDLE_ID'; expected '$EXPECTED_BUNDLE_ID.liveactivity'"

EXTENSION_POINT=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$LIVE_ACTIVITY_PLIST" 2>/dev/null) ||
    fail "the Live Activity extension has no NSExtensionPointIdentifier"
[ "$EXTENSION_POINT" = "com.apple.widgetkit-extension" ] ||
    fail "unexpected Live Activity extension point: '$EXTENSION_POINT'"

EXTENSION_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$LIVE_ACTIVITY_PLIST" 2>/dev/null) ||
    fail "the Live Activity extension has no CFBundleExecutable"
case "$EXTENSION_EXECUTABLE" in
    ''|*/*|.|..) fail "unsafe Live Activity CFBundleExecutable value: '$EXTENSION_EXECUTABLE'" ;;
esac
EXTENSION_EXECUTABLE_PATH="$LIVE_ACTIVITY_PATH/$EXTENSION_EXECUTABLE"
[ -x "$EXTENSION_EXECUTABLE_PATH" ] || fail "the Live Activity executable is missing or not executable"
EXTENSION_ARCHS=$(lipo -archs "$EXTENSION_EXECUTABLE_PATH" 2>/dev/null) || fail "could not inspect Live Activity executable architectures"
case " $EXTENSION_ARCHS " in
    *' arm64 '*) ;;
    *) fail "Live Activity executable does not contain arm64 (found: $EXTENSION_ARCHS)" ;;
esac

if find "$APP_PATH" -name embedded.mobileprovision -print -quit | grep -q .; then
    fail "archive contains an embedded provisioning profile"
fi
if find "$APP_PATH" -type d -name _CodeSignature -print -quit | grep -q .; then
    fail "archive contains a code-signature directory; expected an unsigned app"
fi
if codesign -dv "$APP_PATH" >/dev/null 2>&1; then
    fail "app is already code signed; SideStore should receive the unsigned package"
fi

echo "Olympia IPA validation passed"
echo "  archive: $IPA_PATH"
echo "  bundle:  $BUNDLE_ID"
echo "  archs:   $ARCHS"
echo "  live:    $EXTENSION_BUNDLE_ID ($EXTENSION_ARCHS)"
echo "  root:    Payload/SolarH9.app"
