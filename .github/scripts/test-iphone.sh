#!/usr/bin/env bash
set -euo pipefail
# CI already generated Home.xcodeproj. Select an installed iPhone rather than a particular model.
device="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if match:
        version = tuple(map(int, match[1].split("-")))
        devices.extend((version, d["name"], d["udid"]) for d in entries
                       if d["name"].startswith("iPhone") and d.get("isAvailable") and version[0] >= 17)
if not devices:
    sys.exit("No available iPhone simulator.")
print(max(devices)[2])
')"
echo "Using iPhone simulator $device"
xcodebuild -project Home.xcodeproj -scheme Home -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO \
  -clonedSourcePackagesDirPath "$SPM_DIR" -skipPackagePluginValidation -skipMacroValidation \
  -resultBundlePath "$RUNNER_TEMP/HomeBlueprint.xcresult" \
  test HOME_CLOUD_SYNC=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
