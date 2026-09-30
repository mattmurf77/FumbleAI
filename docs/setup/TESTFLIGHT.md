# Get the Home app onto your testers' iPhones (TestFlight)

TestFlight is Apple's way of installing a test app on up to 100 people's iPhones without putting it on the App Store. This guide covers everything from the Apple account to inviting your 2–5 testers.

There are **two ways to make a build**:

- **Path A: GitHub does it (recommended).** Once it's set up, you click one button on github.com and about 30 minutes later the build is in TestFlight. Your Mac doesn't need Xcode.
- **Path B: Xcode on your Mac.** You build and upload by hand. It's handy as a backup, or if GitHub's Mac machines are having a bad day. See [Path B](#path-b-build-and-upload-from-xcode-on-your-mac).

Parts 1–3 are needed for both paths. Budget about an hour the first time, plus up to 48 hours waiting for Apple to approve your developer membership.

**Terminal:** a few steps use the Mac's Terminal app. It's in Applications › Utilities › Terminal, or press ⌘ Space, type `Terminal`, and press Return. Paste each command and press Return.

---

## Part 1. Accounts

### 1.1 Join the Apple Developer Program ($99/year)

1. Go to <https://developer.apple.com/programs/enroll/> and click **Start your enrollment**.
2. Sign in with your Apple ID. Two-factor authentication must be on, which it usually is.
3. Choose **Individual / Sole Proprietor**. If you have a company with a D-U-N-S number, you can choose **Organization** instead, and the company name will show as the developer.
4. Pay the $99. Approval usually takes a few hours, but can take up to 2 days. Apple emails you when it's done.

### 1.2 Find your Team ID

1. Go to <https://developer.apple.com/account> and scroll to **Membership details**.
2. Copy the **Team ID**, 10 characters like `A1B2C3D4E5`. Save it in your password manager as **HOME_TEAM_ID**.

---

## Part 2. Register the app with Apple

### 2.1 Pick the bundle ID

The bundle ID is the app's permanent, unique name inside Apple's systems. The project's default is:

```
app.fumble.home
```

Use it unless Apple says it's taken in the next step. If it is taken, use something like `com.yourlastname.home`. **Whatever you choose, save it as HOME_BUNDLE_ID**, because it has to match everywhere below.

### 2.2 Create the App ID (with iCloud and Push)

1. Go to <https://developer.apple.com/account/resources/identifiers/list> and click the blue **+** next to "Identifiers".
2. Choose **App IDs**, click **Continue**, choose **App**, and click **Continue**.
3. Fill in the form:
   - **Description:** `Home`
   - **Bundle ID:** choose **Explicit** and type your bundle ID, e.g. `app.fumble.home`.
4. Under **Capabilities**, check:
   - **iCloud**, and choose **Include CloudKit support** if Apple asks. The app stores its data in each user's own iCloud.
   - **Push Notifications**. iCloud uses silent pushes to tell other devices that data changed. Chore reminders are local notifications and don't need this, but sync does.
5. Click **Continue**, then **Register**.

### 2.3 Create the iCloud container

1. On the same Identifiers page, open the drop-down at the top right that says **App IDs** and switch it to **iCloud Containers**.
2. Click the blue **+**, choose **iCloud Containers**, and click **Continue**.
3. Fill in the form:
   - **Description:** `Home`
   - **Identifier:** `iCloud.` followed by your bundle ID, e.g. **`iCloud.app.fumble.home`**
4. Click **Continue**, then **Register**.
5. Link it to the app:
   1. Switch the drop-down back to **App IDs** and click your **Home** App ID.
   2. Next to **iCloud**, click **Edit** (or **Configure**), check `iCloud.app.fumble.home`, and click **Continue**.
   3. Click **Save**. If Apple warns that profiles will be invalidated, click **Confirm**; that's fine at this stage.

### 2.4 Create the app in App Store Connect

1. Go to <https://appstoreconnect.apple.com> › **Apps**, click the blue **+** (top left), and choose **New App**.
2. Fill in the form:
   - **Platforms:** iOS
   - **Name:** the name testers see, e.g. `Home by Fumble`. It must be unique across the whole App Store. If it's taken, tweak it; you can change it later.
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** pick the one from 2.2 in the list.
   - **SKU:** `home-v1`. This is an internal label and never shown.
   - **User Access:** Full Access
3. Click **Create**. You don't need to fill in any App Store pages; TestFlight doesn't need them.

---

## Part 3. The App Store Connect API key

This key lets GitHub (or fastlane) sign the app and upload it for you, without your password.

1. In App Store Connect, go to **Users and Access** (top menu) › **Integrations** tab › **App Store Connect API** › **Team Keys**.
   - The first time, you may see **Request Access**. Click it and agree; it's instant for the account holder.
2. Click **Generate API Key**, or the **+** button.
3. Fill in the form and click **Generate**:
   - **Name:** `GitHub TestFlight`
   - **Access:** **Admin**. The Admin role is needed so Xcode can create and use Apple's cloud-managed signing certificate on GitHub's machines.
4. Save three things:
   - **Issuer ID:** shown above the list of keys, a long ID like `57246542-96fe-1a63-e053-0824d011072a`. Save it as **APP_STORE_CONNECT_ISSUER_ID**.
   - **Key ID:** shown in the row for your new key, 10 characters like `2X9R4HXF34`. Save it as **APP_STORE_CONNECT_KEY_ID**.
   - **Download API Key:** click it. You get a file named `AuthKey_2X9R4HXF34.p8` in your Downloads folder. **Apple lets you download it only once.** Keep a copy in your password manager as an attachment.
5. GitHub needs the file as one line of text. In Terminal, run this, replacing `2X9R4HXF34` with your Key ID:

   ```sh
   base64 -i ~/Downloads/AuthKey_2X9R4HXF34.p8 | pbcopy
   ```

   Nothing is printed; the text is now on your clipboard, ready for the next step. This value is **APP_STORE_CONNECT_KEY_P8**.

---

## Path A: build and upload with GitHub (recommended)

### A.1 Add the GitHub secrets

1. On github.com, open **mattmurf77/FumbleAI**.
2. Click **Settings** (top tab) › **Secrets and variables** (left sidebar) › **Actions**.
3. For each row below, click **New repository secret**, type the **Name** exactly as shown, paste the **Secret**, and click **Add secret**:

| Name | Where it comes from | Required? |
|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | Part 3, Key ID | Yes |
| `APP_STORE_CONNECT_ISSUER_ID` | Part 3, Issuer ID | Yes |
| `APP_STORE_CONNECT_KEY_P8` | Part 3, step 5 (the clipboard, base64 text) | Yes |
| `HOME_TEAM_ID` | Part 1.2, Team ID | Yes |
| `HOME_BUNDLE_ID` | Part 2.1, e.g. `app.fumble.home` | Yes |
| `HOME_SERVER_URL` | [RENDER.md](RENDER.md), Step 4 | Optional |
| `HOME_API_KEY` | [RENDER.md](RENDER.md), Step 1 | Optional |

Secrets can't be viewed again after saving, only replaced. That's normal.

### A.2 Run the TestFlight workflow

1. On github.com, open **mattmurf77/FumbleAI** and click the **Actions** tab.
2. In the left list, click **TestFlight**.
3. Click the grey **Run workflow** button on the right.
4. Pick the branch to build (usually `main`) and click the green **Run workflow**.
5. Refresh after a few seconds, and a yellow dot appears. Click it to watch the progress. It takes about 20–35 minutes.
6. A **green check** means the build was uploaded. A **red X** means it failed; click into it, open the red step, and see the troubleshooting table at the end of this guide.

What the workflow does for you:

- Generates the Xcode project with XcodeGen.
- Signs the app with Apple's automatic signing, using your API key.
- Sets the build number: GitHub's run number, and always higher than the last build in TestFlight.
- Uploads the build to TestFlight.

### A.3 Wait for Apple's processing

1. In App Store Connect › **Apps** › **Home** › **TestFlight** tab, the new build shows **Processing** for 5–30 minutes. Apple also emails you when it's done.
2. If the build shows **Missing Compliance**, click **Manage**. Choose **None of the algorithms mentioned above** (the app only uses Apple's standard HTTPS and iCloud encryption) and click **Save**. The developers can add a setting to the app so this question never comes up again.

---

## Part 4. Invite your 2–5 testers

There are two kinds of testers. For family and close friends, **internal** is the quickest.

| | Internal testers | External testers |
|---|---|---|
| Who | People added to your App Store Connect team (up to 100) | Anyone with an email address (up to 10,000) |
| Apple review | **None**. They get builds within minutes of processing. | **Beta App Review** for the first build (usually under a day), then quick checks for later builds |
| What they see | They can sign in to App Store Connect with a limited role | Nothing but TestFlight |
| Best for | You, your household | Friends you don't want on your team |

### 4.1 Internal testers

1. **Add each person to your team.**
   1. Go to App Store Connect › **Users and Access** › **People** and click **+**.
   2. Enter their name and the email of **their Apple ID**.
   3. Choose the role **Marketing** or **Customer Support** (limited access), and under **Apps** give them access to **Home** only.
   4. Click **Invite**. They must accept the email invitation.
2. **Make a tester group.**
   1. Go to **Apps** › **Home** › **TestFlight** › **Internal Testing** (left sidebar) and click **+**.
   2. Name the group `Household`, and keep **Enable automatic distribution** checked. New builds then go to this group automatically.
   3. Click **Create**.
3. **Add the testers.** In the group, click **+** next to **Testers**, check each person, and click **Add**.

### 4.2 External testers

1. Go to **TestFlight** › **External Testing** (left sidebar), click **+**, name the group `Friends`, and click **Create**.
2. Under **Test Information** (left sidebar), fill in:
   - a short **Beta App Description**, e.g. "Floor-plan-based home organizer"
   - a **Feedback Email**
   - your **contact details**
   - **Sign-In Required:** off (the app has no login)
3. In the `Friends` group, add testers by email (**+** › **Add New Testers**), or turn on a **Public Link** to text to people.
4. Under **Builds**, click **+**, choose the build, and click **Submit for Review**. Apple usually approves the first build within 24 hours; later builds of the same version are often approved automatically.

### 4.3 What your testers do

1. Install **TestFlight** from the App Store on their iPhone.
2. Open the invitation email on the iPhone and tap **View in TestFlight** (or open your public link).
3. Tap **Install**. The app appears on their home screen with an orange dot next to its name.
4. They need to be signed in to **iCloud** (Settings › [their name] › iCloud) for the app to save and sync.

TestFlight builds expire after **90 days**. Run the workflow again to send a fresh one.

---

## Path B: build and upload from Xcode on your Mac

Use this if you'd rather not use GitHub Actions, or as a backup. Parts 1–3 still apply; you don't need the GitHub secrets.

### B.1 Install the tools (one time)

1. **Install Xcode.** Open the **App Store** on your Mac, search **Xcode**, and click **Get**. It's large, so allow an hour. Open it once, agree to the license, and when it offers platforms, make sure **iOS** is checked.
2. **Point the command-line tools at Xcode.** In Terminal:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```

   It asks for your Mac password. Nothing shows while you type; that's normal.

3. **Install Homebrew**, the standard Mac installer for developer tools. Skip this if `brew --version` already prints a version.

   ```sh
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   When it finishes, it prints "Next steps". On Apple-silicon Macs (M1, M2, M3, M4), run these two lines so your Mac can find `brew`:

   ```sh
   echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
   eval "$(/opt/homebrew/bin/brew shellenv)"
   ```

4. **Install XcodeGen and the GitHub tool:**

   ```sh
   brew install xcodegen gh
   ```

5. **Download the code.** The first line opens a browser to sign in to GitHub; choose **GitHub.com**, **HTTPS**, and **Login with a web browser**.

   ```sh
   gh auth login
   gh repo clone mattmurf77/FumbleAI ~/FumbleAI
   ```

### B.2 Each time you make a build

1. **Get the latest code and generate the Xcode project:**

   ```sh
   cd ~/FumbleAI
   git pull
   cd HomeApp
   xcodegen generate
   open Home.xcodeproj
   ```

2. **Sign in to Xcode (first time only).** Go to **Xcode** menu › **Settings…** › **Accounts**, click **+** › **Apple ID**, and sign in with your developer Apple ID.
3. **Set the team.**
   1. In the left sidebar, click the blue **Home** project icon at the top.
   2. Under **Targets**, select **Home** and open the **Signing & Capabilities** tab.
   3. Check **Automatically manage signing**, and set **Team** to your name or team.
   4. If your bundle ID isn't `app.fumble.home`: open the **Build Settings** tab, search `HOME_BUNDLE_ID`, and double-click the value to change it.
4. **Optional: the Render service.** In **Build Settings**, search `HOME_SERVER_URL` and `HOME_API_KEY` and paste the values from [RENDER.md](RENDER.md).
5. **Set the build number.**
   1. Open the **General** tab.
   2. Under **Identity**, set **Build** to a number **higher than the latest build in TestFlight**, for example the last number plus 1. Every upload needs a new build number.
6. **Choose the device.** In the toolbar at the top center, click the device name and choose **Any iOS Device (arm64)**.
7. **Archive.** Choose **Product** menu › **Archive**. It takes 2–10 minutes, and then the **Organizer** window opens.
8. **Upload.**
   1. Select the new archive and click **Distribute App**.
   2. Choose **TestFlight & App Store**. On older Xcode versions, choose **App Store Connect** › **Upload**.
   3. Click **Distribute**, and accept the defaults on any following screens.
9. Continue at [A.3](#a3-wait-for-apples-processing) (processing) and [Part 4](#part-4-invite-your-25-testers) (testers).

Running `xcodegen generate` rebuilds the project file, so repeat steps 3–5 after each regenerate.

---

## Troubleshooting

| What you see | What to do |
|---|---|
| Workflow fails at **Check required secrets** | The named secret is missing or misspelled. Check A.1; names are case-sensitive. |
| `APP_STORE_CONNECT_KEY_P8 does not decode to a .p8 private key` | Re-run the `base64 -i … \| pbcopy` command from Part 3 and replace the secret. |
| `No profiles for 'app.fumble.home' were found` or `No Account for Team` | The App ID (2.2) doesn't exist, **HOME_BUNDLE_ID** doesn't match it exactly, or **HOME_TEAM_ID** is wrong. |
| `Cloud signing permission error` or `not allowed to create certificates` | Your API key isn't **Admin**. Make a new Admin key (Part 3) and update the three key secrets. |
| `You have reached the maximum number of certificates` | Go to <https://developer.apple.com/account/resources/certificates/list>, delete old **Apple Development** certificates named "Created via API", and run again. Each GitHub run can create one. |
| `The bundle version must be higher than the previously uploaded version` | Run it again; the workflow reads TestFlight's latest number. On Path B, raise **Build** in the General tab. |
| iCloud entitlement or container errors | Redo 2.3. The container must be exactly `iCloud.<your bundle ID>` and be checked on the App ID. |
| The build never appears in TestFlight | Check email from Apple about "ITMS" issues. Processing can take up to an hour. |
| Testers don't get the build | Internal testers: make sure **automatic distribution** is on for the group, or add the build to the group by hand. External testers: the build has to pass Beta App Review first. |

Related: [RENDER.md](RENDER.md) (optional helper service) · [README.md](README.md) (index).
