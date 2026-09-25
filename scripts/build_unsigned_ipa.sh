#!/bin/bash

set -euo pipefail

fail() {
    echo "Olympia IPA build failed: $*" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_PATH="$PROJECT_ROOT/SolarH9.xcodeproj"
SCHEME=SolarH9
BUNDLE_ID=${SOLARH9_BUNDLE_ID:-com.olympia.app}
OUTPUT_INPUT=${SOLARH9_IPA_PATH:-$PROJECT_ROOT/Olympia.ipa}

case "$BUNDLE_ID" in
    ''|*' '*) fail "SOLARH9_BUNDLE_ID must be a non-empty bundle identifier without spaces" ;;
esac

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild was not found; install Xcode 16 or newer"
command -v ditto >/dev/null 2>&1 || fail "the macOS 'ditto' command is required"
command -v zip >/dev/null 2>&1 || fail "the 'zip' command is required"
xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild is unavailable; select a full Xcode installation with 'sudo xcode-select -s /Applications/Xcode.app/Contents/Developer'"
[ -d "$PROJECT_PATH" ] || fail "project not found: $PROJECT_PATH"

OUTPUT_DIR=$(dirname -- "$OUTPUT_INPUT")
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
OUTPUT_PATH="$OUTPUT_DIR/$(basename -- "$OUTPUT_INPUT")"
case "$OUTPUT_PATH" in
    *.ipa) ;;
    *) fail "SOLARH9_IPA_PATH must end in .ipa" ;;
esac

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/solarh9-unsigned-build.XXXXXX")
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

DERIVED_DATA="$WORK_DIR/DerivedData"
STAGING_DIR="$WORK_DIR/package"

echo "Building Olympia for a generic physical iPhone (unsigned)..."
if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    SOLARH9_BUNDLE_ID="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    ONLY_ACTIVE_ARCH=NO \
    build; then
    fail "xcodebuild did not produce an unsigned device build; review the errors above"
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/SolarH9.app"
[ -d "$APP_PATH" ] || fail "expected build product was not created: $APP_PATH"
[ -f "$APP_PATH/Info.plist" ] || fail "built app is missing Info.plist"
if find "$APP_PATH" -name embedded.mobileprovision -print -quit | grep -q .; then
    fail "the build unexpectedly embedded a provisioning profile"
fi
if find "$APP_PATH" -type d -name _CodeSignature -print -quit | grep -q .; then
    fail "the build unexpectedly contains a code signature"
fi

mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/SolarH9.app"
rm -f "$OUTPUT_PATH"
(
    cd "$STAGING_DIR"
    zip -qry "$OUTPUT_PATH" Payload
)

[ -s "$OUTPUT_PATH" ] || fail "IPA packaging produced no output"
SOLARH9_BUNDLE_ID="$BUNDLE_ID" "$SCRIPT_DIR/validate_ipa.sh" "$OUTPUT_PATH"

echo "Unsigned SideStore package created: $OUTPUT_PATH"
