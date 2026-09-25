# App Store Connect — listing copy

Paste-ready text for the App Store Connect record. Character limits are noted where
App Store Connect enforces them.

## App information

| Field | Value |
|---|---|
| Name (30) | WattBench |
| Subtitle (30) | Live power meter for FNB58 |
| Bundle ID | com.thebench.wattbench |
| SKU | wattbench-ios |
| Primary language | English (U.S.) |
| Primary category | Utilities |
| Secondary category | Developer Tools |
| Content rights | Does not contain third-party content |
| Age rating | 4+ (no questionable content in any category) |
| Price | Free |
| Privacy policy URL | https://github.com/RedThoroughbred/FNB58-MacOS/blob/main/PRIVACY.md |
| Support URL | https://github.com/RedThoroughbred/FNB58-MacOS/issues |
| Marketing URL | https://github.com/RedThoroughbred/FNB58-MacOS |
| Copyright | 2026 Seth Egger |

## Promotional text (170)

See exactly what your USB charger, cable or device is doing — live voltage, current and power from your FNIRSI FNB58, right on your iPhone.

## Description (4000)

WattBench turns your iPhone into a wireless display and data logger for the FNIRSI FNB58 USB power meter.

Connect over Bluetooth and watch voltage, current and power update in real time, with scrolling charts you can zoom from 10 seconds to 2 minutes. Start a recording to capture a whole charge cycle, and the app integrates energy (Wh) and capacity (mAh) as it goes — using real timestamps, not an assumed sample rate. Saved sessions keep every sample, so you can review the curve later or export it as CSV and open it in Numbers, Excel or Python.

FEATURES
• Live voltage, current and power readouts with big, glanceable numbers
• Scrolling charts for V, I and W with adjustable time window
• Session recording with energy (Wh), capacity (mAh), averages, peaks and duration
• Session history with a full-resolution chart of each recording
• CSV export via the share sheet — AirDrop it, save it to Files, or send it anywhere
• Remembers your meter and reconnects with one tap
• Demo mode so you can explore the app before your meter arrives
• No account, no ads, no analytics, no network access — your data stays on your phone

REQUIREMENTS
Works with the FNIRSI FNB58 USB power meter over Bluetooth Low Energy. Turn on Bluetooth in the meter's settings menu, then tap Connect. Bluetooth carries voltage, current and power; D+/D- line voltages and temperature are only available from the meter's screen or over USB.

WattBench is an independent project and is not affiliated with or endorsed by FNIRSI.

## Keywords (100, comma-separated)

FNB58,FNIRSI,USB power meter,USB tester,voltage,current,watt,charger,battery capacity,mAh,data logger

## What's New (first release)

First release.

## App Privacy (nutrition label)

Data Not Collected — the app collects no data of any kind. No tracking.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is set in Info.plist, so the compliance question is skipped on upload.

## App Review information

**Contact:** Seth Egger — phone and email as on the developer account.

**Sign-in required:** No.

**Notes for the reviewer:**

This app is a Bluetooth companion for a physical piece of test equipment, the FNIRSI FNB58 USB power meter. Without the meter it will show "Not connected".

To evaluate every screen without the hardware: tap **Connect**, then **Try with demo data**. The app then streams simulated readings, clearly labeled "Demo data" in the status banner. From there you can start a recording, stop it, open it under the Sessions tab and export it as CSV — the exact flow a user follows with a real meter.

The app uses Bluetooth only in the foreground, makes no network requests, has no accounts, and stores recordings only in its own Documents folder.

## Screenshots

iPhone 6.9" (1320 × 2868) — `ios/AppStore/screenshots/`. The app is iPhone-only, so no iPad set is needed.

1. `01-live.png` — Live view with readouts and charts
2. `02-recording.png` — Recording in progress with energy/capacity
3. `03-sessions.png` — Sessions list
4. `04-session-detail.png` — Session detail

Captured from the iPhone 17 Pro Max simulator in demo mode (`xcrun simctl io <udid> screenshot`).
Replace with real-meter captures from an iPhone when available — same sizes.
