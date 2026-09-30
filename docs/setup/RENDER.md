# Set up the Render helper service

This guide puts the small helper service (the `server/` folder) on your Render account. It takes about 15 minutes, and you only do it once.

**What the service does.** It looks up your house outline from OpenStreetMap and serves the list of appliance templates. It **stores no user data**. The only thing it remembers is a short-lived cache of public map lookups, and that cache is wiped whenever the service restarts.

**Do you need it?** Not strictly. The v1 design has the phone call OpenStreetMap directly. The service is the backup plan from the design docs, for when calling OpenStreetMap directly becomes a problem. Setting it up now is cheap, and it's free.

**Cost:** $0. It runs on Render's free plan. The only catch is that a free service "falls asleep" after about 15 minutes with no traffic. The first request after that takes around 30–60 seconds while it wakes up; later requests are fast. For 2–5 testers that's fine.

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

---

## Step 2. Connect Render to GitHub

You can skip this step if you've already connected GitHub to Render.

1. Go to <https://dashboard.render.com> and sign in.
2. Click your account name (top right) › **Account Settings**.
3. Under **Git Deployment Credentials** (or **GitHub**), click **Connect GitHub**.
4. GitHub asks which repositories Render may see. Choose **Only select repositories**, pick **FumbleAI**, and click **Install** (or **Save**).

---

## Step 3. Create the service from the Blueprint

The repository contains a file called `render.yaml`, which Render calls a "Blueprint". It already describes the whole service: free plan, the `server` folder, Node 22 and the health check. You don't have to fill in any of those settings yourself.

1. In the Render dashboard, click **New +** (top right) › **Blueprint**.
2. Pick the **FumbleAI** repository and click **Connect**.
3. **Branch:** choose `main`. If the code hasn't been merged into `main` yet, choose the branch that contains the `server/` folder and `render.yaml`.
4. **Blueprint Name:** type `home`.
5. Render reads `render.yaml` and shows one service called **home-server**. It asks you for two values:
   - **HOME_API_KEY:** paste the key from Step 1.
   - **OVERPASS_CONTACT:** your email address. OpenStreetMap asks apps to include a contact address so they can reach you if something goes wrong. It's sent only to OpenStreetMap. You can leave it blank.
6. Click **Apply** (or **Deploy Blueprint**).
7. Wait about 2–3 minutes. The service page shows **Deploy live** in green when it's ready.

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

## Everyday care

- **Updates deploy themselves.** When a change to the `server/` folder reaches the branch you picked, Render redeploys automatically.
- **Logs:** go to the home-server page › **Logs**. The service never logs addresses or coordinates.
- **Change the key:** go to home-server › **Environment**, edit `HOME_API_KEY`, and click **Save Changes**; the service restarts. Then update the GitHub secret and make a new TestFlight build, because the old key stops working in older builds.
- **Turn it off:** go to home-server › **Settings**, scroll down, and click **Suspend Service** (or **Delete Service**).

## Troubleshooting

| What you see | What to do |
|---|---|
| The Blueprint says "no render.yaml found" | You picked a branch that doesn't have the file. Pick the branch with `render.yaml` at the top level. |
| The deploy fails with "Unsupported engine" | Check that **Environment** has `NODE_VERSION` = `22`. |
| The first request is very slow | The free service was asleep. This is normal. |
| `401 unauthorized` | The `X-Home-Key` value doesn't match `HOME_API_KEY` in Render. Watch for extra spaces when pasting. |
| `503 upstream_rate_limited` | OpenStreetMap is asking everyone to slow down. Try again in a minute. |

For developers, the API details are in `server/README.md`.
