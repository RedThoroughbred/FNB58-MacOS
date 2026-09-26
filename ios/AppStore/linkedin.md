# LinkedIn post draft (publish after App Review approval)

I just shipped my first paid iPhone app: **WattBench** — a Bluetooth companion for the FNIRSI FNB58 USB power meter.

Bench people know the problem: the meter shows numbers, but the moment you want to *log* a charge cycle, compare two cables, or know how many mAh actually went into a power bank, you're squinting at a tiny screen and writing things down.

WattBench turns the phone into the instrument face:
• live voltage / current / power with rolling digits and peak hold
• a trip counter for Wh and mAh since you plugged in
• recordings that keep going with the screen locked — and survive a crash
• session reports with a zoomable chart, range statistics, markers and CSV export
• threshold alerts that notify you when something goes wrong

Built natively in SwiftUI with CoreBluetooth, no accounts, no analytics, nothing leaves the phone.

Fun engineering notes: the meter's Bluetooth frames were reverse-engineered by the community; the app journals every sample to disk in a compact binary format so a force-quit loses at most ten seconds; and the live display is throttled to 5 Hz so it stays smooth on a 10 Hz data stream.

App Store link: <insert after approval>
GitHub (desktop companion + protocol notes): https://github.com/RedThoroughbred/FNB58-MacOS

#iOS #SwiftUI #Electronics #USB #Bluetooth #IndieDev
