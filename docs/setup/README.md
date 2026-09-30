# Setup guides

Step-by-step guides for getting the Home iPhone app to your testers. They're written for a Mac user who doesn't write code.

| Guide | What it covers | Needed? |
|---|---|---|
| [TESTFLIGHT.md](TESTFLIGHT.md) | Apple Developer account, the App ID with iCloud and Push, the iCloud container, the App Store Connect app, the API key, GitHub secrets, running the TestFlight build, inviting testers, and building from Xcode as a backup | **Yes** |
| [RENDER.md](RENDER.md) | The helper service on Render (house-outline lookup, appliance templates) and the Postgres database that stores in-app feedback; how to read feedback | Needed for feedback |

**Suggested order:** Part 1 of TESTFLIGHT.md first, because Apple's approval can take up to 2 days. Set up Render while you wait, then finish TESTFLIGHT.md.

## Everything you'll save

Keep these in your password manager:

| Name | What it is | Used by |
|---|---|---|
| `HOME_TEAM_ID` | Apple Developer Team ID (10 characters) | GitHub secret |
| `HOME_BUNDLE_ID` | App bundle ID, default `app.fumble.home` | GitHub secret; iCloud container is `iCloud.<bundle ID>` |
| `APP_STORE_CONNECT_KEY_ID` | API key ID | GitHub secret |
| `APP_STORE_CONNECT_ISSUER_ID` | API issuer ID | GitHub secret |
| `APP_STORE_CONNECT_KEY_P8` | The `.p8` key file, base64-encoded | GitHub secret |
| `HOME_SERVER_URL` | Render service URL, e.g. `https://home-server-xxxx.onrender.com` | GitHub secret (optional); app build setting |
| `HOME_API_KEY` | Random key shared by the app and the Render service | Render env var and GitHub secret (optional); app build setting |

## What's in the repository

| Path | What it is |
|---|---|
| `render.yaml` | Render Blueprint for the helper service |
| `server/` | The helper service (Node 22, no dependencies). API details are in `server/README.md` |
| `fastlane/`, `Gemfile`, `Gemfile.lock` | The `beta` lane that builds `HomeApp/Home.xcodeproj` and uploads it to TestFlight |
| `.github/workflows/testflight.yml` | The **TestFlight** button (Actions tab, run by hand) |
| `.github/workflows/ios-build.yml` | Checks that the app builds and its package tests pass on every change to `HomeApp/` |
| `.github/workflows/server-test.yml` | Runs the server tests on every change to `server/` |
