#!/usr/bin/env bash
# Captures App Store screenshots in the simulator.
#
#   tools/screenshots.sh                 # all devices below
#   tools/screenshots.sh "iPad Pro 13-inch (M5)"
#
# For each device: boot, force the 9:41 status bar, run the Screenshots
# scheme (UITests/ScreenshotTests.swift, which launches the app's staged
# scenes from App/ScreenshotScenario.swift), and export the PNGs to
# screenshots/<device>/. Audio is muted in staged scenes.
#
# Device choice (App Store Connect, Nov 2026): a 6.1" iPhone set is required
# (1206x2622, iPhone 17), as is a 13" iPad set (2064x2752) since the app runs
# on iPad. iPhone Duo screenshots (outer 1398x2034, inner 2007x2853) are
# optional until April 2027 and earn the "Made for iPhone Duo" badge.
# The Duo simulator boots folded (outer display); for inner-display shots,
# unfold it from Simulator's Device menu, then run: tools/screenshots.sh "iPhone Duo"
# (the folded outer display doesn't rotate, so it gets no landscape shot).
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DEVICES=("$@")
if [ ${#DEVICES[@]} -eq 0 ]; then
    DEVICES=("iPhone 17" "iPad Pro 13-inch (M5)" "iPhone Duo")
fi

OUT=screenshots
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcodegen --quiet

for device in "${DEVICES[@]}"; do
    echo "==> $device"
    udid=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
name = sys.argv[1]
for runtime, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['name'] == name:
            print(d['udid']); sys.exit()
sys.exit('no simulator named ' + name)" "$device")

    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl status_bar "$udid" override \
        --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --operatorName "" \
        --batteryState charged --batteryLevel 100

    result="$WORK/$udid.xcresult"
    xcodebuild test -quiet \
        -project ChromaNoise.xcodeproj -scheme Screenshots \
        -destination "id=$udid" -resultBundlePath "$result" \
        CODE_SIGNING_ALLOWED=NO

    xcrun simctl status_bar "$udid" clear

    raw="$WORK/$udid-attachments"
    xcrun xcresulttool export attachments --path "$result" --output-path "$raw" >/dev/null
    dest="$OUT/$device"
    rm -rf "$dest" && mkdir -p "$dest"
    # The manifest maps exported file names to the attachment names
    # ("01-paint", ...) set in the test.
    python3 - "$raw" "$dest" <<'EOF'
import json, os, re, shutil, sys
raw, dest = sys.argv[1:]
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for a in test["attachments"]:
        name = re.sub(r"_\d+_[0-9A-F-]+$", "", os.path.splitext(a["suggestedHumanReadableName"])[0])
        shutil.copy(os.path.join(raw, a["exportedFileName"]), os.path.join(dest, name + ".png"))
EOF
    # Accepted App Store sizes (portrait or landscape): 6.1" iPhone, 6.9"
    # iPhone, 13" iPad, iPhone Duo outer and inner displays.
    for f in "$dest"/*.png; do
        w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/ {print $2}')
        h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/ {print $2}')
        case "${w}x${h}" in
            1206x2622|2622x1206|1179x2556|2556x1179|1320x2868|2868x1320|1290x2796|2796x1290|2064x2752|2752x2064|2048x2732|2732x2048|1398x2034|2034x1398|2007x2853|2853x2007) ok="" ;;
            *) ok="  <-- not an App Store size" ;;
        esac
        echo "    $(basename "$f")  ${w}x${h}${ok}"
    done
done

echo "Screenshots are in $OUT/"
