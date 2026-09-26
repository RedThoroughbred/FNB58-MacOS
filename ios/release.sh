#!/bin/zsh
# Build, test, archive and upload WattBench to App Store Connect.
#
#   ./release.sh            # build number from project.yml (CURRENT_PROJECT_VERSION)
#   BUILD_NUMBER=7 ./release.sh
#   ./release.sh --no-upload   # archive only (build/WattBench.xcarchive)
#   TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17' ./release.sh
#                           # run the tests on another simulator (default: iPhone 17 Pro Max;
#                           # `xcrun simctl list devices` shows what this Mac has)
#
# Requirements: xcodegen (brew install xcodegen) and an Apple ID with access to
# team CC8X33MU92 signed in under Xcode > Settings > Accounts. Signing is
# automatic; -allowProvisioningUpdates lets xcodebuild register the bundle ID
# and create/refresh profiles and the cloud-managed distribution certificate.
set -euo pipefail
cd "$(dirname "$0")"

UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0
BUILD_SETTINGS=()
[[ -n "${BUILD_NUMBER:-}" ]] && BUILD_SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"

echo "▸ Generating Xcode project"
xcodegen generate -q

echo "▸ Running unit tests ($TEST_DESTINATION)"
xcodebuild test -project WattBench.xcodeproj -scheme WattBench \
  -destination "$TEST_DESTINATION" \
  -derivedDataPath build -quiet

echo "▸ Archiving (Release)"
rm -rf build/WattBench.xcarchive
xcodebuild archive -project WattBench.xcodeproj -scheme WattBench -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/WattBench.xcarchive \
  -allowProvisioningUpdates -quiet "${BUILD_SETTINGS[@]}"

if (( UPLOAD )); then
  echo "▸ Exporting and uploading to App Store Connect"
  xcodebuild -exportArchive -archivePath build/WattBench.xcarchive \
    -exportOptionsPlist ExportOptions.plist -exportPath build/export \
    -allowProvisioningUpdates
  echo "✓ Uploaded. Processing takes a few minutes; the build then appears under TestFlight / the version's Build section in App Store Connect."
else
  echo "✓ Archive at build/WattBench.xcarchive"
fi
