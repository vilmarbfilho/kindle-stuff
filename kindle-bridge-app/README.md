# Building a Standalone IPA Locally (Free — No Apple Developer Account Required)

This guide explains how to build the Kindle Bridge iPhone app as a standalone `.ipa` file and install it directly on your iPhone using Xcode's free personal team signing. No paid Apple Developer account ($99/year) is needed for personal use.

---

## Requirements

| Tool | Version | How to get |
|---|---|---|
| macOS | 12 or later | — |
| Xcode | 14 or later | Mac App Store |
| Node.js | 18 or 20 | [nodejs.org](https://nodejs.org) |
| Expo CLI | latest | `npm install -g expo-cli` |
| iPhone | iOS 15+ | — |
| USB cable | Lightning or USB-C | — |

> **Important:** Xcode must be fully installed (not just the Command Line Tools). Download it from the Mac App Store — it is a large download (~10 GB).

---

## Step 1 — Install dependencies

Inside the `kindle-bridge-app` folder:

```bash
npm install --legacy-peer-deps
```

---

## Step 2 — Generate the native iOS project

Expo's prebuild command generates the `ios/` folder with all native Xcode files:

```bash
npx expo prebuild --platform ios --clean
```

This will:
- Create `ios/kindle-bridge-app.xcworkspace`
- Create `android/` (you can ignore this)
- Install CocoaPods dependencies automatically

If CocoaPods installation fails, run manually:

```bash
cd ios
pod install
cd ..
```

---

## Step 3 — Open the project in Xcode

```bash
open ios/kindle-bridge-app.xcworkspace
```

> Always open the `.xcworkspace` file, **not** the `.xcodeproj` file. The workspace includes CocoaPods dependencies.

---

## Step 4 — Configure free signing in Xcode

1. In the left sidebar, click the root project **kindle-bridge-app** (blue icon at the top)
2. Select the **kindle-bridge-app** target in the middle panel
3. Click the **Signing & Capabilities** tab
4. Check **Automatically manage signing**
5. Under **Team**, click the dropdown and select **Add an Account...**
6. Sign in with your Apple ID (free account is fine)
7. After signing in, select **Your Name (Personal Team)**

Xcode will automatically generate a free provisioning profile. You may see a warning about the bundle identifier — if so, change it to something unique in the **Bundle Identifier** field (e.g. `com.yourname.kindlebridge`).

---

## Step 5 — Connect your iPhone

1. Connect your iPhone to your Mac via USB cable
2. Unlock your iPhone
3. If prompted on the iPhone tap **Trust This Computer**
4. In Xcode, click the device selector at the top (it may show a simulator name)
5. Select your iPhone from the list

---

## Step 6 — Build and install

Press the **▶ Run** button in Xcode (or `Cmd + R`).

Xcode will:
1. Compile the app (~2–5 minutes on first build)
2. Install it directly on your iPhone
3. Launch it automatically

---

## Step 7 — Trust the developer certificate on iPhone

The first time you tap the app icon, iOS shows an **"Untrusted Developer"** dialog and blocks the app from opening. This is normal for apps installed outside the App Store.

To fix it:

1. Open **Settings** on your iPhone
2. Tap **General**
3. Scroll down and tap **VPN & Device Management**
4. Under **Developer App**, tap the entry showing your Apple ID (e.g. `Apple Development: yourname@gmail.com (XXXXXXXXX)`)
5. Tap **Trust "Apple Development: yourname@gmail.com"**
6. Tap **Trust** on the confirmation dialog

Go back to the home screen and tap the app icon — it will now open normally.

After tapping Trust the app runs fully standalone — no Mac, no Expo Go, no terminal needed.

> **Note:** This trust step is required once per Apple ID per device. After reinstalling the app (e.g. after the 7-day expiry) you do not need to trust again unless you use a different Apple ID.

---

## Rebuilding after code changes

Any time you change the JavaScript/TypeScript source files:

```bash
# Rebuild the JS bundle
npx expo export --platform ios

# Then press Run again in Xcode (Cmd + R)
```

Or for quick iteration during development, just run:

```bash
npx expo start
```

And use Expo Go while developing, then do a full Xcode build only when you want a standalone version.

---

## Known limitations of free signing

| Limitation | Details |
|---|---|
| **7-day expiry** | The provisioning profile expires every 7 days. Reconnect iPhone to Mac and press Run again to renew. |
| **Device limit** | Free account allows up to 3 devices per year. |
| **No TestFlight** | Free accounts cannot distribute via TestFlight. For TestFlight you need a paid Apple Developer account ($99/year) at [developer.apple.com](https://developer.apple.com/programs/enroll). |
| **No App Store** | Free accounts cannot submit to the App Store. |

For personal use on your own iPhone the free approach works well — just rebuild once a week.

---

## Troubleshooting

### `ios/` folder does not exist after prebuild
Run prebuild again and check for errors:
```bash
npx expo prebuild --platform ios --clean 2>&1 | tail -50
```

### CocoaPods not found
```bash
sudo gem install cocoapods
cd ios && pod install
```

### `xcworkspace` not found after prebuild
Make sure you open the `.xcworkspace` not the `.xcodeproj`:
```bash
open ios/kindle-bridge-app.xcworkspace
```

### Build fails with "No profiles for bundle identifier"
Change the bundle identifier in Xcode (**Signing & Capabilities** → **Bundle Identifier**) to something unique like `com.yourname.kindlebridge2` and try again.

### "Untrusted Developer" dialog when tapping the app icon
This is expected on first install. Follow these steps:
1. **Settings → General → VPN & Device Management**
2. Tap your Apple ID entry under **Developer App**
3. Tap **Trust "Apple Development: yourname@gmail.com"**
4. Tap **Trust** to confirm
5. Return to the home screen and open the app normally

### App crashes immediately after install
The JavaScript bundle may be missing. Run `npx expo export --platform ios` first, then rebuild in Xcode.

---

## Quick reference — full flow from scratch

```bash
# 1. Install dependencies
npm install --legacy-peer-deps

# 2. Generate iOS project
npx expo prebuild --platform ios --clean

# 3. Open in Xcode
open ios/kindle-bridge-app.xcworkspace

# 4. In Xcode:
#    - Select your iPhone as the target device
#    - Set Team to your Apple ID (Personal Team)
#    - Press Run (Cmd + R)

# 5. On iPhone (first time only):
#    Settings → General → VPN & Device Management
#    → tap your Apple ID entry → Trust → Trust
```

Total time from scratch: ~15–20 minutes (mostly Xcode compilation on first build, ~3 minutes on subsequent builds).