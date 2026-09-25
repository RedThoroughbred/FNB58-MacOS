# Privacy Policy

_Last updated: September 25, 2026_

This policy covers the **iPhone app** in this repository (the Bluetooth companion app for the FNIRSI FNB58 USB power meter) and the **desktop web monitor**.

## What the app does with data

- The app connects to your power meter over Bluetooth Low Energy and displays the voltage, current and power it reports.
- Recordings you choose to save are stored **only on your device**, in the app's own Documents folder. You can view, export (CSV) or delete them at any time. Deleting the app deletes them. CSV exports are written to a temporary folder for the share sheet and are never uploaded by the app.
- The identifier of the last meter you connected to, the trip counter and your settings are remembered on your device so the app can reconnect quickly and pick up where you left off.

## What we do not do

- We do **not** collect, transmit or sell any personal data or measurement data.
- The app has **no accounts**, **no analytics**, **no advertising** and **no tracking**.
- The app makes **no network requests**. Bluetooth is used solely to talk to your meter.

## Permissions

- **Bluetooth** — required to discover and connect to the power meter. The app never scans in the background. Bluetooth stays connected in the background only while a recording is in progress, so the recording continues with the screen locked; nothing is transmitted anywhere.
- **Notifications** (optional) — local notifications only, for alert rules and finished recordings you set up yourself. There is no push service.

## Desktop web monitor

The desktop application runs on your own computer and serves a dashboard on your local network. Sessions and exports are written to folders inside the project directory on that computer. Nothing is sent to us.

## Children

The app does not knowingly collect any information from anyone, including children.

## Changes

If this policy changes, the updated text will be published at this same address with a new date.

## Contact

Questions: open an issue at <https://github.com/RedThoroughbred/FNB58-MacOS/issues>.
