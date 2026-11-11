#!/usr/bin/env bash
# Archives ChromaNoise and uploads it to App Store Connect (TestFlight), then
# waits for Apple to finish processing.
#
#   tools/release.sh            # requires a clean, pushed working tree
#   tools/release.sh --dirty    # allow uncommitted changes (test builds)
#
# Build number = git commit count, so every upload is unique and increasing.
# The version (1.0, ...) is MARKETING_VERSION in project.yml.
#
# Auth: Xcode's signed-in Apple ID for signing/upload (see AUTH below), and
# an App Store Connect API key for status checks, configured outside the repo:
#   ~/.appstoreconnect/chromanoise.env        ASC_KEY_ID, ASC_ISSUER_ID
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "${1:-}" != "--dirty" ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "Working tree has uncommitted changes; commit them or pass --dirty." >&2
        exit 1
    fi
    # Against the remote-tracking ref as last fetched; no network needed.
    if ! git merge-base --is-ancestor HEAD '@{upstream}' 2>/dev/null; then
        echo "HEAD isn't on its upstream branch; push first or pass --dirty." >&2
        exit 1
    fi
fi

set -a; source ~/.appstoreconnect/chromanoise.env; set +a
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
# Signing for the App Store uses Apple's cloud-managed distribution
# certificate, which only Admin-role API keys may use. By default sign and
# upload with the Apple ID signed in to Xcode; set ASC_SIGN_WITH_KEY=1 if the
# key has the Admin role (needed for headless use, e.g. CI). The key is
# always used to check processing status (tools/asc.py).
AUTH=(-allowProvisioningUpdates)
if [ "${ASC_SIGN_WITH_KEY:-0}" = 1 ]; then
    AUTH+=(-authenticationKeyPath "$KEY_PATH"
           -authenticationKeyID "$ASC_KEY_ID"
           -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

BUILD=$(git rev-list --count HEAD)
ARCHIVE="build/ChromaNoise-$BUILD.xcarchive"
echo "==> Archiving build $BUILD ($(git rev-parse --short HEAD))"

xcodegen --quiet
rm -rf "$ARCHIVE"
xcodebuild archive -quiet \
    -project ChromaNoise.xcodeproj -scheme ChromaNoise -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}"

OPTIONS_DIR=$(mktemp -d)
trap 'rm -rf "$OPTIONS_DIR"' EXIT
OPTIONS="$OPTIONS_DIR/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>upload</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>578G67F2NQ</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> Uploading build $BUILD"
LOG="build/upload-$BUILD.log"
status=0
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "build/upload-$BUILD" \
    -exportOptionsPlist "$OPTIONS" "${AUTH[@]}" > "$LOG" 2>&1 || status=$?
grep -E "EXPORT|Upload|error" "$LOG" || true
if [ $status -ne 0 ]; then
    echo "Upload failed; full log: $LOG" >&2
    exit $status
fi

echo "==> Waiting for App Store Connect to process build $BUILD"
tools/asc.py wait-build "$BUILD"
echo "Build $BUILD is ready in TestFlight."
