#!/usr/bin/env bash
# Builds Home Blueprint for the iOS Simulator, launches it in demo mode (in-memory sample house) on each screen
# listed in SCREENS, and saves PNG screenshots plus an index.html gallery to $OUT_DIR.
#
# Runs on a Mac with Xcode and XcodeGen (CI: .github/workflows/screenshots.yml; locally: same command).
# Screens are DemoLaunch.Screen ids (HomeApp/App/Features/Demo/DemoLaunch.swift).
#
# Env: SCREENS (space-separated, default: all), APPEARANCE (light|dark|both, default light),
#      DEVICE (simulator model, default "iPhone 16 Pro"), OUT_DIR (default ./screenshots), SETTLE (seconds, default 6)
set -euo pipefail

ALL_SCREENS="onboarding home plan plan-outside todos quick-add projects stuff add-outside outdoor-templates settings"
SCREENS="${SCREENS:-$ALL_SCREENS}"
[ "$SCREENS" = "all" ] && SCREENS="$ALL_SCREENS"
APPEARANCE="${APPEARANCE:-light}"
DEVICE="${DEVICE:-iPhone 16 Pro}"
export DEVICE
OUT_DIR="$(cd "$(dirname "${OUT_DIR:-screenshots}")" && pwd)/$(basename "${OUT_DIR:-screenshots}")"
SETTLE="${SETTLE:-6}"
BUNDLE_ID="${HOME_BUNDLE_ID:-app.fumble.home}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="$ROOT/build/screenshots-dd"

mkdir -p "$OUT_DIR"
cd "$ROOT/HomeApp"
[ -d Home.xcodeproj ] || xcodegen generate

echo "==> Building for the simulator"
xcodebuild -project Home.xcodeproj -scheme Home -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
  ${SPM_DIR:+-clonedSourcePackagesDirPath "$SPM_DIR"} -skipPackagePluginValidation -skipMacroValidation \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" -quiet
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Home.app"
[ -d "$APP" ] || { echo "Built app not found at $APP"; exit 1; }

echo "==> Creating a $DEVICE simulator"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].split(".")[-1].startswith("iOS")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')"
[ -n "$RUNTIME" ] || { echo "No iOS simulator runtime installed"; exit 1; }
DEVICE_TYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json,sys,os
want=os.environ["DEVICE"]
ts=json.load(sys.stdin)["devicetypes"]
exact=[t for t in ts if t["name"]==want]
phones=[t for t in ts if t["name"].startswith("iPhone") and "Pro" in t["name"] and "Max" not in t["name"]]
print((exact or phones[-1:] or [{"identifier":""}])[0]["identifier"])')"
UDID="$(xcrun simctl create "Screenshots" "$DEVICE_TYPE" "$RUNTIME")"
cleanup() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true; xcrun simctl delete "$UDID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

case "$APPEARANCE" in
  both) MODES="light dark" ;;
  *) MODES="$APPEARANCE" ;;
esac

i=0
for mode in $MODES; do
  xcrun simctl ui "$UDID" appearance "$mode"
  for screen in $SCREENS; do
    i=$((i + 1))
    name="$(printf '%02d' "$i")-$screen-$mode.png"
    echo "==> $name"
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -HomeDemo YES -HomeDemoScreen "$screen" >/dev/null
    # The first launch also warms up the app; give it longer.
    if [ "$i" -eq 1 ]; then sleep $((SETTLE * 2)); else sleep "$SETTLE"; fi
    xcrun simctl io "$UDID" screenshot --type=png "$OUT_DIR/$name" >/dev/null
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  done
done

echo "==> Writing gallery"
python3 - "$OUT_DIR" <<'PY'
import html, os, sys
out = sys.argv[1]
shots = sorted(f for f in os.listdir(out) if f.endswith(".png"))
cards = "\n".join(
    f'<figure><img src="{html.escape(f)}" loading="lazy" alt=""><figcaption>{html.escape(f[3:-4])}</figcaption></figure>'
    for f in shots)
page = f"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Home Blueprint screenshots</title>
<style>body{{font:15px -apple-system,system-ui,sans-serif;margin:24px;background:#f4f2ee;color:#222}}
main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:20px}}
figure{{margin:0}}img{{width:100%;border-radius:22px;box-shadow:0 2px 10px #0002}}
figcaption{{text-align:center;margin-top:6px;color:#555}}</style>
<h1>Home Blueprint screenshots</h1><main>{cards}</main>"""
open(os.path.join(out, "index.html"), "w").write(page)
print(f"{len(shots)} screenshots")
PY
