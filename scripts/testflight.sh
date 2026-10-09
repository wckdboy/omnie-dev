#!/bin/sh
# SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
# SPDX-License-Identifier: Apache-2.0
# Archives a release build and uploads it to App Store Connect for TestFlight.
# Uses the Xcode account signed in for team XKA8CGC2AB. Bump CURRENT_PROJECT_VERSION in project.yml
# before each upload; App Store Connect rejects a build number it has already seen.
set -eu
cd "$(dirname "$0")/.."
OUT=.build/testflight
rm -rf "$OUT" && mkdir -p "$OUT"
xcodegen generate -q
xcodebuild -project OmnieDev.xcodeproj -scheme OmnieDev -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath .build/dd-archive \
  -archivePath "$OUT/OmnieDev.xcarchive" -allowProvisioningUpdates archive -quiet
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>XKA8CGC2AB</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/OmnieDev.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -allowProvisioningUpdates
