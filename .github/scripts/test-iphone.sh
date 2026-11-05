#!/usr/bin/env bash
set -euo pipefail
suite="${1:?Select HomeTests or HomeUITests}"
case "$suite" in
  HomeTests|HomeUITests) ;;
  *) echo "Unknown iPhone test target" >&2; exit 2 ;;
esac
# CI already generated Home.xcodeproj. Select an installed iPhone rather than a particular model.
device="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if match:
        version = tuple(map(int, match[1].split("-")))
        # Apple FB22237318: the iOS 26.5 headless StoreKit daemon rejects local .storekit files.
        if sys.argv[1] == "HomeTests" and version[:2] != (26, 2):
            continue
        devices.extend((version, d["name"], d["udid"]) for d in entries
                       if d["name"].startswith("iPhone") and d.get("isAvailable") and version[0] >= 17)
if not devices:
    sys.exit("No available iPhone simulator.")
print(max(devices)[2])
' "$suite")"
echo "Using simulator $device for $suite"
xcrun simctl list devices available | awk -v id="$device" '/-- iOS / {runtime=$0} index($0,id) {print runtime, $0}'
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl bootstatus "$device" -b
selection=(-only-testing:"$suite")
if [[ "$suite" == HomeTests ]]; then
  selection+=(-only-testing:HomeUITests/HomeBriefReviewScreenshotTests)
else
  selection+=(-skip-testing:HomeUITests/HomeBriefReviewScreenshotTests)
fi
xcodebuild -project Home.xcodeproj -scheme Home -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 240 \
  -clonedSourcePackagesDirPath "$SPM_DIR" -skipPackagePluginValidation -skipMacroValidation \
  "${selection[@]}" -resultBundlePath "$RUNNER_TEMP/$suite.xcresult" \
  test HOME_CLOUD_SYNC=NO CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
