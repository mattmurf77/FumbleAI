---
name: app-screenshots
description: Capture real screenshots of the Home Blueprint iPhone app in the iOS Simulator via GitHub Actions (no Mac or Xcode needed in the session), review them, and share a gallery. Use when asked for screenshots, "what does the app look like", to visually check a UI change before merging, or to refresh mockups with the real app.
---

# App screenshots (Home Blueprint)

The app is SwiftUI and can't run on the Linux session machine. GitHub's macOS runners can: the **Screenshots**
workflow builds the app for the iOS Simulator, launches it in **demo mode** (in-memory sample house, nothing real
touched) on each screen, and uploads PNGs plus an `index.html` gallery as the `screenshots` artifact.

Pieces:
- `HomeApp/App/Features/Demo/DemoLaunch.swift` — demo mode. Launch args `-HomeDemo YES -HomeDemoScreen <id>`;
  `DemoLaunch.Screen` lists the ids and says which tab, floor and sheet each one opens.
- `.github/scripts/take-screenshots.sh` — build, create/boot a simulator, set a clean status bar (9:41, full
  battery), launch each screen, screenshot, write the gallery. Also runs as-is on any Mac with Xcode + XcodeGen.
- `.github/workflows/screenshots.yml` — `workflow_dispatch` (inputs `screens`, `appearance`, `device`) and PRs that
  touch the screenshot tooling.

## Run it

1. **Trigger** `screenshots.yml` with `mcp__github__actions_run_trigger` (`method: run_workflow`, `ref`: the branch to
   photograph — usually the working branch, or `main`). Inputs, all optional:
   - `screens`: `all` (default) or space-separated ids, e.g. `home plan-outside quick-add`
   - `appearance`: `light` (default), `dark` or `both`
   - `device`: simulator model, default `iPhone 16 Pro`
   `workflow_dispatch` only works once the workflow is on the default branch; before that, a PR that touches the
   screenshot tooling runs it automatically.
2. **Wait.** A cold run takes ~10–15 min (Swift package resolution + Debug build), warm ~6–8. First check at
   ~4 min to catch early failures, then every ~5 min (`mcp__github__actions_get get_workflow_run`). Don't poll faster.
3. **On failure**, get logs: `actions_get get_workflow_run_logs_url` → `curl -sSL -o logs.zip "<url>"` into the
   scratchpad → `unzip` → `grep -E "error:|==>|Error"`. Compile errors are the app's; simulator errors (no runtime,
   device type) are the script's — fix `take-screenshots.sh`.
4. **Download**: `actions_list list_workflow_run_artifacts` (resource_id = run id) → find `screenshots` →
   `actions_get download_workflow_run_artifact` (resource_id = artifact id) gives a URL →
   `curl -sSL -o shots.zip "<url>"` into the scratchpad → `unzip -o shots.zip -d shots`.
5. **Review every PNG with the Read tool** before showing anyone: wrong screen, spinner still showing (raise
   `SETTLE`), clipped text, empty states where sample data should be, overlapping controls (the floating feedback
   button is expected, bottom-right above the tab bar). Note real UI problems as findings.
6. **Share**: publish a gallery as an Artifact (embed the PNGs as `files` next to an HTML page, or base64 `data:`
   URIs if small), title like "Home Blueprint screens", with a one-line caption per screen and the findings.
   Don't commit screenshots to the repo.

## Add a screen

1. Add a case to `DemoLaunch.Screen` (raw value = the id) and map it in `tab`, `levelID` and/or `sheet`
   (add a `DemoSheet` case for screens that are sheets). Use `SampleHome` ids for specific rooms or floors.
2. Add the id to `ALL_SCREENS` in `take-screenshots.sh` (keep the order: it's the gallery order).
3. Run it with `screens: <new-id>` to check just that one.

## Notes

- Demo mode uses `AppEnvironment.preview(sample:)`: no SQLite, iCloud, calendar or notification side effects, so it's
  safe to run on any branch. Without `-HomeDemo YES` the app is unchanged.
- Each run creates and deletes its own simulator, so state never leaks between runs.
- Artifacts are kept 14 days.
