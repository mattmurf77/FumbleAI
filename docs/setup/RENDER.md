# Set up the Render helper service

This guide puts the small helper service (the `server/` folder) on your Render account. It takes about 15 minutes, and you only do it once.

**What the service does.** It looks up your house outline from OpenStreetMap, serves the list of appliance templates, and **collects in-app feedback** (the Bug / Polish / Idea button in the app). Feedback is saved in a small Render Postgres database. That's the only thing it stores: the category, the text the tester typed, which screen they were on, the app and iOS version, the iPhone model and a random install number. No screenshots, names, emails or locations.

**Do you need it?** For feedback, yes: without it the app keeps feedback on the phone and never sends it. For the map lookup, not strictly; the phone can call OpenStreetMap directly.

**Cost:** the web service runs on Render's free plan ($0). The feedback database is on the smallest paid Postgres plan (a few dollars a month; check the price Render shows before you click Apply). A free web service "falls asleep" after about 15 minutes with no traffic. The first request after that takes around 30–60 seconds while it wakes up; later requests are fast. The app sends feedback in the background, so testers don't wait.

> **Already set up the service before feedback existed?** Skip to [Add the feedback database](#add-the-feedback-database-existing-service).

---

## What you need

- Your **Render account** (you already have one): <https://dashboard.render.com>
- Access to the GitHub repository **mattmurf77/FumbleAI**
- A Mac with the **Terminal** app. It's in Applications › Utilities › Terminal, or press ⌘ Space, type `Terminal`, and press Return.

---

## Step 1. Make a secret key for the app

The key is a long random password. The app sends it with every request, so strangers who find the service's web address can't use it.

In Terminal, paste this line and press Return:

```sh
openssl rand -hex 24
```

It prints something like `3f9c1a…` (48 characters). **Copy it and save it in your password manager** (for example Passwords or 1Password) under a name like "Home HOME_API_KEY". You'll paste it in two places: in Render (Step 3) and in GitHub (Step 6).

Run the same line **a second time** to make a different key for reading feedback. Save it as "Home HOME_ADMIN_KEY". This one is only for you: never put it in the app or in GitHub.

---

## Step 2. Connect Render to GitHub

You can skip this step if you've already connected GitHub to Render.

1. Go to <https://dashboard.render.com> and sign in.
2. Click your account name (top right) › **Account Settings**.
3. Under **Git Deployment Credentials** (or **GitHub**), click **Connect GitHub**.
4. GitHub asks which repositories Render may see. Choose **Only select repositories**, pick **FumbleAI**, and click **Install** (or **Save**).

---

## Step 3. Create the service from the Blueprint

The repository contains a file called `render.yaml`, which Render calls a "Blueprint". It already describes everything: the free web service (the `server` folder, Node 22, the health check) and the feedback database **home-blueprint-db**. You don't have to fill in any of those settings yourself.

1. In the Render dashboard, click **New +** (top right) › **Blueprint**.
2. Pick the **FumbleAI** repository and click **Connect**.
3. **Branch:** choose `main`. If the code hasn't been merged into `main` yet, choose the branch that contains the `server/` folder and `render.yaml`.
4. **Blueprint Name:** type `home`.
5. Render reads `render.yaml` and shows a service called **home-server** and a database called **home-blueprint-db**. It asks you for these values:
   - **HOME_API_KEY:** paste the key from Step 1.
   - **HOME_ADMIN_KEY:** paste the second key from Step 1 (the feedback password).
   - **OVERPASS_CONTACT:** your email address. OpenStreetMap asks apps to include a contact address so they can reach you if something goes wrong. It's sent only to OpenStreetMap. You can leave it blank.
6. Click **Apply** (or **Deploy Blueprint**).
7. Wait about 3–5 minutes (the database is created first). The service page shows **Deploy live** in green when it's ready.

---

## Step 4. Copy the service URL

At the top of the **home-server** page, under the name, is a link like:

```
https://home-server-xxxx.onrender.com
```

Copy it and save it in your password manager next to the key as **HOME_SERVER_URL**. Don't include a slash at the end.

---

## Step 5. Check that it works

In Terminal, replace the URL and key below with yours and run each line. The first request can take up to a minute if the service is asleep.

```sh
curl https://home-server-xxxx.onrender.com/health
```

You should see `{"ok":true,"version":"1.0.0+…", …}`.

```sh
curl -H "X-Home-Key: PASTE-YOUR-KEY-HERE" "https://home-server-xxxx.onrender.com/v1/footprint?lat=40.748440&lon=-73.985664"
```

You should see a `"building"` with a `"polygon"` (this example is the Empire State Building) and a list of `"roads"`.

```sh
curl -H "X-Home-Key: PASTE-YOUR-KEY-HERE" https://home-server-xxxx.onrender.com/v1/templates
```

You should see a long list of templates, including Refrigerator, HVAC furnace and Light fixture.

If the lookup returns `{"error":"unauthorized"}`, the key you typed doesn't match the one in Render. If it returns `upstream_unavailable`, OpenStreetMap is busy; wait a minute and try again.

Then send a test feedback item (this is what the app does):

```sh
curl -X POST -H "X-Home-Key: PASTE-YOUR-KEY-HERE" -H "Content-Type: application/json" -d '{"category":"idea","message":"Test from Terminal","page":"Terminal"}' https://home-server-xxxx.onrender.com/v1/feedback
```

You should see `{"id":"…","createdAt":"…"}`. Now open it in the browser: see [Read feedback](#read-feedback).

---

## Step 6. Give the URL and key to the app

The iPhone app reads two **build settings**, which end up in the app's Info.plist:

| Build setting | Value |
|---|---|
| `HOME_SERVER_URL` | the URL from Step 4, e.g. `https://home-server-xxxx.onrender.com` |
| `HOME_API_KEY` | the key from Step 1 |

If they're empty, the app skips the service and talks to OpenStreetMap directly, which is the v1 default.

**For TestFlight builds made by GitHub:** add both as GitHub secrets.

1. On github.com, open **mattmurf77/FumbleAI**.
2. Click **Settings** › **Secrets and variables** › **Actions**.
3. Click **New repository secret**. For **Name**, type `HOME_SERVER_URL`; for **Secret**, paste the URL. Click **Add secret**.
4. Repeat with the name `HOME_API_KEY` and the key.

The TestFlight workflow passes both into the build automatically. See [TESTFLIGHT.md](TESTFLIGHT.md).

**For builds you make in Xcode on your Mac:** open the project, click the blue **Home** project icon at the top of the left sidebar, then select the **Home** target › **Build Settings** tab. Search for `HOME_SERVER_URL` and double-click its value to paste the URL. Do the same for `HOME_API_KEY`. (Running `xcodegen generate` again resets these values, so set them again after each regenerate.)

> The key ends up inside the app, so it isn't a strong secret. It stops casual misuse of a free service. The service holds no private data, so the risk is low.

---

## Add the feedback database (existing service)

Do this once if you created **home-server** before the feedback feature. The updated `render.yaml` adds the database; Render reads it when you sync the Blueprint.

1. **Make the feedback password.** In Terminal run `openssl rand -hex 24`, copy the result and save it in your password manager as "Home HOME_ADMIN_KEY".
2. **Get the code onto the Blueprint's branch.** The change must be merged into the branch your Blueprint uses (usually `main`). Merging the pull request on github.com is enough.
3. **Sync the Blueprint.** In <https://dashboard.render.com> click **Blueprints** in the left sidebar, then **home**. If you see **Manual Sync**, click it (with auto-sync on, Render may already have started). Render lists what it will change: **create database home-blueprint-db** and **update home-server** (new `DATABASE_URL` and `HOME_ADMIN_KEY` settings). Check the database price it shows, then click **Apply**.
   - If Render asks for **HOME_ADMIN_KEY**, paste the key from item 1.
4. **Set the password if Render didn't ask.** Open **home-server** › **Environment**. If `HOME_ADMIN_KEY` is missing or empty, click **Edit** (or **Add Environment Variable**), enter the name `HOME_ADMIN_KEY` and paste the key, then **Save Changes**. The service restarts.
5. **Check `DATABASE_URL`.** On the same **Environment** page you should see `DATABASE_URL` linked to **home-blueprint-db**. If it's missing: open **home-blueprint-db**, click **Connect** › **Internal**, copy the URL, and add it to home-server as `DATABASE_URL`.
6. **Check the logs.** Open **home-server** › **Logs**. After the restart you should see `feedback table ready`. If you see `feedback table not ready yet`, wait until the database page shows **Available**, then click **Manual Deploy** › **Deploy latest commit** on home-server.
7. Send the test feedback from Step 5 and open [Read feedback](#read-feedback).

---

## Read feedback

Open this address in Safari or Chrome on your Mac or iPhone (replace the URL and the key with yours):

```
https://home-server-xxxx.onrender.com/admin/feedback?key=PASTE-YOUR-ADMIN-KEY
```

You'll see every piece of feedback, newest first: category (Bug, Polish, Idea), the screen it was sent from, the message, the device and app version. Tap the buttons at the top to show only one category or status. Bookmark the page; the key is part of the address, so don't share the bookmark.

**Mark items as handled** (optional, from Terminal). Copy an item's id (the long code at the bottom of each card) and run:

```sh
curl -X PATCH -H "X-Home-Admin-Key: PASTE-YOUR-ADMIN-KEY" -H "Content-Type: application/json" -d '{"status":"done"}' https://home-server-xxxx.onrender.com/v1/feedback/PASTE-THE-ID
```

Status can be `new`, `triaged` or `done`. Then use the **done** / **new** buttons on the page to filter.

**Download everything as JSON** (for a spreadsheet or to paste into Claude):

```sh
curl -H "X-Home-Admin-Key: PASTE-YOUR-ADMIN-KEY" "https://home-server-xxxx.onrender.com/v1/feedback?limit=500" > ~/Desktop/feedback.json
```

---

## Everyday care

- **Updates deploy themselves.** When a change to the `server/` folder reaches the branch you picked, Render redeploys automatically.
- **Logs:** go to the home-server page › **Logs**. The service never logs addresses or coordinates.
- **Change the key:** go to home-server › **Environment**, edit `HOME_API_KEY`, and click **Save Changes**; the service restarts. Then update the GitHub secret and make a new TestFlight build, because the old key stops working in older builds.
- **Change the feedback password:** edit `HOME_ADMIN_KEY` the same way. Nothing else needs updating; just use the new key in your bookmark.
- **Database backups and size:** open **home-blueprint-db**. Paid Postgres plans keep automatic backups; feedback text is tiny, so the smallest disk lasts a very long time.
- **The database is private.** It only accepts connections from home-server (`ipAllowList: []` in `render.yaml`). To use a desktop tool like TablePlus, add your IP under home-blueprint-db › **Networking** and use the **External** connection URL.
- **Turn it off:** go to home-server › **Settings**, scroll down, and click **Suspend Service** (or **Delete Service**).

## Troubleshooting

| What you see | What to do |
|---|---|
| The Blueprint says "no render.yaml found" | You picked a branch that doesn't have the file. Pick the branch with `render.yaml` at the top level. |
| The deploy fails with "Unsupported engine" | Check that **Environment** has `NODE_VERSION` = `22`. |
| The first request is very slow | The free service was asleep. This is normal. |
| `401 unauthorized` | The `X-Home-Key` value doesn't match `HOME_API_KEY` in Render. Watch for extra spaces when pasting. |
| `503 upstream_rate_limited` | OpenStreetMap is asking everyone to slow down. Try again in a minute. |
| `503 feedback_unavailable` | `DATABASE_URL` isn't set on home-server. See [Add the feedback database](#add-the-feedback-database-existing-service), item 5. |
| `503 database_unavailable` | The database is starting, suspended or unreachable. Check home-blueprint-db shows **Available**. The app keeps feedback on the phone and retries later. |
| `/admin/feedback` says `not_found` | `HOME_ADMIN_KEY` isn't set on home-server. |
| `/admin/feedback` says `unauthorized` | The `?key=` value doesn't match `HOME_ADMIN_KEY`. Watch for spaces when pasting. |
| The Blueprint sync says the plan is invalid | Render renamed its Postgres plans. Open `render.yaml`, change `plan: 0.1c-256mb` under `databases` to the smallest paid plan Render lists (older name: `basic-256mb`), merge, and sync again. |

For developers, the API details are in `server/README.md`.
