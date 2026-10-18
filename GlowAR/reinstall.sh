#!/bin/bash
# Rebuilds Glow AR with the free Personal Team and installs it on the iPhone over the cable.
# Run it when the app stops opening (free signing expires every 7 days).
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
command -v xcodegen >/dev/null && xcodegen generate >/dev/null   # picks up new source files
xcodebuild -project GlowAR.xcodeproj -scheme GlowAR -configuration Debug \
  -destination 'id=00008150-000C39A901D8C01C' -derivedDataPath build/dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=2GT3LQ5GT7 CODE_SIGN_STYLE=Automatic \
  build -quiet
xcrun devicectl device install app --device 0896D6DE-785A-5DC2-9950-57542EE30687 \
  build/dd/Build/Products/Debug-iphoneos/GlowAR.app
echo "Glow AR installed."
