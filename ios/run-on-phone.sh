#!/bin/zsh
# Build WattBench (Debug) and install + launch it on a paired iPhone.
#
#   ./run-on-phone.sh                 # first paired/available device
#   ./run-on-phone.sh "Seth's iPhone" # by name (as shown by `xcrun devicectl list devices`)
#   ./run-on-phone.sh <identifier>    # by devicectl identifier
#
# Needs an Apple ID with access to the team signed in under Xcode > Settings > Accounts,
# the phone paired with this Mac (USB or Wi-Fi) and Developer Mode enabled on it.
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
    | python3 -c "import sys,json; d=[x for x in json.load(sys.stdin)['result']['devices'] if x.get('connectionProperties',{}).get('pairingState')=='paired']; print(d[0]['identifier'] if d else '')")
  [[ -z "$DEVICE" ]] && { echo "No paired device found. Run: xcrun devicectl list devices"; exit 1; }
fi

echo "▸ Generating Xcode project"
xcodegen generate -q

echo "▸ Building for device"
xcodebuild -project WattBench.xcodeproj -scheme WattBench -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -allowProvisioningUpdates build -quiet

APP=build-device/Build/Products/Debug-iphoneos/WattBench.app
echo "▸ Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "installationURL|error" || true

echo "▸ Launching"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.thebench.wattbench
