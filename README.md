# AwayLatch

AwayLatch locks your Mac when a monitored Bluetooth Low Energy device moves away. It runs in the menu bar and works with devices such as an Apple Watch or iPhone. Use the macOS Apple Watch setting for unlocking.

[简体中文](README.zh-cn.md)

## Build from source

You need a Mac with Bluetooth Low Energy support and macOS 15.6 or later. The project was tested with Xcode 27.2.

1. Clone the repository and open the project.

   ```sh
   git clone https://github.com/LFGN-S/AwayLatch.git
   cd AwayLatch
   open AwayLatch.xcodeproj
   ```

2. Select the **AwayLatch** scheme and **My Mac**, then choose **Product → Run**. Allow Bluetooth access on first launch. Notification access lets AwayLatch report which device triggered a lock.
3. Open **Devices to Monitor** in the menu bar and select one or more nearby devices. The menu shows devices macOS reports as paired by default. Turn on **Include Other Nearby Devices** to find additional devices. Selected devices stay at the top of the list when their signal is missing.

Menus follow the preferred languages in macOS, with English as the fallback.

## How locking works

Each device is monitored independently. Once AwayLatch has detected a selected device nearby, that device can trigger a lock when its signal stays weak or goes missing.

For nearby devices monitored through Bluetooth advertisements, AwayLatch opens a scan every quarter of the departure confirmation time. Each scan ends as soon as all those devices have a qualifying reading. A full window with no qualifying reading counts as one failure for that device. The window length comes from observed broadcasts.

After three consecutive failures for the same device, AwayLatch scans continuously through the deadline. The deadline is measured from the **start of the first failed scan**. A qualifying reading resets that device’s confirmation. With a 120-second setting, the three sampled scans start 30 seconds apart.

AwayLatch uses continuous monitoring when the setting is too short to fit the sampled scans and final check. Monitoring pauses while the Mac is locked, asleep, or automatic locking is disabled. Opening the device submenu starts continuous discovery.

## Settings

| Option | What it controls |
| --- | --- |
| Lock Threshold (RSSI) | Defaults to −70 dBm. Options range from −45 to −90 dBm in 5 dBm steps. Choose **Disable Automatic Locking** to pause departure locking. |
| Departure Confirmation Time | Presets from 10 to 600 seconds. Continuous-only monitoring starts the timer when a weak or missing signal is detected. |
| Lock with Screen Saver | Starts the screen saver. The macOS Lock Screen settings control when a password is required. |
| Open at Login | Starts AwayLatch when you log in. |

## Upgrading from BLELock

Quit and remove BLELock before opening AwayLatch. AwayLatch imports selected devices and lock settings on first launch. macOS may ask for Bluetooth and notification access again.

## Signing

Debug and Release use local ad hoc signing with Hardened Runtime enabled. Anyone can build and run the project locally with this configuration. To distribute a downloadable app, sign with your own **Developer ID Application** identity and submit the app for Apple notarization. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Credits and license

AwayLatch is based on BLELock by Shawn Rain, which was based on BLEUnlock by Takeshi Sone. [BLELock](https://github.com/ShawnRn/BLELock) · [BLEUnlock](https://github.com/ts1/BLEUnlock)

Licensed under the MIT License. [LICENSE](LICENSE)
