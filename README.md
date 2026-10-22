# Epson Legacy Connect

A native macOS utility for connecting older Epson printers to Wi-Fi without WPS, discovering them on the local network, and adding them to a Mac. English and Ukrainian interfaces are included.

**v2 development preview; roadmap target v5.** Independent community software, not an Epson product. The tested Wi-Fi configuration target is the **Epson Stylus Photo 1500W**. Other model profiles do not imply that USB configuration has been tested on those printers.

See [ROADMAP.md](ROADMAP.md) for release acceptance checks and [PROTOCOL.md](PROTOCOL.md) for reconstructed protocol evidence and hardware-testing limits.

## What works

- USB configuration of the 1500W using its own network interface; no router WPS button is needed.
- The printer scans for networks. Search, select a network, and enter its WPA2 password locally.
- Setup checks the assigned address, selected network, and printer TCP port before showing success.
- Bonjour discovery of supported Epson model profiles.
- **Add to this Mac** creates the wireless queue with the matching installed Epson driver. If the driver is missing, the same flow downloads and verifies the official installer, opens macOS Installer, and automatically continues after installation. macOS administrator authorization and Epson's licence steps still require the user.
- Built-in PDF/photo selection and preview, with the macOS print dialog and Epson driver options. Dialog routing and cancellation were tested; physical printing through the new in-app flow still needs a release-build test.
- Pending-job viewing and confirmed cancellation of the current user's own jobs. Cancellation rechecks queue membership and ownership.
- A printer-health dashboard probes the actual network print port and offers driver/queue repair. Physical power/cable/router problems require the appropriate physical intervention.
- A native menu-bar companion provides status, ink readings and print/job/care shortcuts. Its live preview lets you show or hide ink levels, the Wi-Fi shortcut and the menu icon. English and Ukrainian layouts were inspected.
- Printer care reads the selected driver's advertised commands. An ink request completed through the wireless queue; nozzle checks and cleaning still need physical verification.
- Original macOS app icon with reproducible vector artwork in `Tools/GenerateIcon.swift`.
- Official components are downloaded from Epson and checked by hash/signature. Public source and app builds contain no Epson binaries.
- The app does not save Wi-Fi passwords. Credentials are cleared from the form when submitted or when leaving setup.
- The printer retains the Wi-Fi settings itself. The Mac does not need to remain on for direct printer networking.

## Hardware verification

On one Epson Stylus Photo 1500W, the following were verified with real hardware:

1. USB discovery and direct IJCP network reads.
2. Wireless scanning and WPA2 provisioning without WPS.
3. Network printing with the USB cable disconnected; the owner confirmed the physical test page.
4. The printer was powered off and on, remained unplugged from USB, and returned to the network with its print port reachable.
5. Ukrainian navigation and network discovery were inspected in the running app.

The fresh-Mac installer continuation and other model profiles require additional hardware/clean-machine testing. Do not interpret passing core checks as proof of those workflows.

## Compatibility

| Model family | Network discovery / queue profile | USB Wi-Fi writes |
| --- | --- | --- |
| Stylus Photo 1500 / 1500W | Implemented; hardware tested | Hardware tested |
| Stylus Photo 1430 / Artisan 1430 | Profile included; unverified hardware | Disabled pending verification |
| Artisan 730 / 837 | Profile included; unverified hardware | Disabled pending verification |
| XP-600 / 700 / 750 / 800 / 850 | Profile included; unverified hardware | Disabled pending verification |

Profiles map exact advertised model names to Epson PPDs included in the verified official installer. Unknown models are not silently treated as a 1500W. This is not universal support for every Epson printer with a WPS button.

Requires macOS 13 or later. Apple silicon is the hardware-tested platform. The baseline universal build also ran Intel diagnostics under Rosetta; physical Intel hardware remains untested. Release architecture is identified on each build.

## iPhone, iPad, and AirPrint

Joining Wi-Fi does **not** add AirPrint firmware. The tested printer advertises a raw network printing service, and the owner's standard iOS print dialog did not find an AirPrint printer.

Epson lists [Epson iPrint](https://apps.apple.com/app/epson-iprint/id326876192) on the [1500W support page](https://www.epson.eu/en_EU/support/sc/epson-stylus-photo-1500w/s/s1075). Mobile printing through that app still needs an owner-confirmed test. Use the same main network; guest isolation can prevent discovery.

No supported firmware upgrade adding native AirPrint has been verified. An AirPrint bridge is a separate possible architecture requiring an always-on Mac or dedicated device. The development preview now includes an **experimental, opt-in Mac AirPrint bridge** under AirPrint. It uses the macOS IPP server and the installed Epson driver. Eligible Macs advertise readiness and elect one host; healthy hosts remain stable. The app can run quietly with its menu icon hidden. At least one Mac must remain awake with the app running; login startup is not implemented yet.

The approved network signature is saved locally. Automatic hosting pauses on a different network; enable it there explicitly only if it is trusted. This is a convenience boundary, not network authentication. Global macOS printer sharing is not enabled.

**Not release verified:** physical iPhone/iPad output, multiple-Mac takeover, stable printer identity across host changes and active-upload handover. Jobs accepted by an unavailable host are not replayed. The system PPD server currently advertises PostScript although the forwarding backend rejects it; PDF/JPEG/URF/PWG raster are accepted. The backend reports success when the local CUPS queue accepts a job, not when paper output is confirmed. These issues must be resolved before calling AirPrint production ready.

## Build

Install Apple's Command Line Tools or Xcode, then:

```sh
swift run PrinterCoreChecks
bash build-app.sh /private/tmp/Epson-Legacy-Connect.app
# Optional universal Intel + Apple silicon build:
ELC_UNIVERSAL=1 bash build-app.sh /private/tmp/Epson-Legacy-Connect-Universal.app
```

Move the resulting app into Applications. Build/sign outside an iCloud-synced folder: File Provider metadata can prevent strict bundle signing. The local script creates an ad-hoc signature, not an Apple notarized distribution signature. It does not disable Gatekeeper or other macOS protections.

On first USB setup, choose **Prepare USB setup**, review the downloaded Epson component licence, and enable the component. Driver installation is available from the app and from the Add flow. Cached downloads are kept in the user's Application Support folder for offline reuse.

The optional integration check contacts official Epson download hosts, verifies components and caches them, but does not install software, accept licences, or write printer settings:

```sh
swift run ComponentChecks
```

## Current limitations

- Maintenance has driver-gated commands; physical nozzle/cleaning tests and alignment integration remain unfinished. Power-timer writes remain disabled until transport and readback are hardware verified.
- Desktop widgets are on the v5 roadmap, not installed. A genuine WidgetKit extension needs separate build, signing, shared-data and desktop behavior verification. The current environment has Command Line Tools and no full Xcode installation.
- Driver detection is currently strongest for the 1500W; other profiles and macOS releases need clean-install testing.
- A first-time component download needs internet access and may fail if Epson replaces an asset. Hash changes stop the flow rather than executing an unverified replacement.
- Only WPA2 configuration is enabled in the current verified flow. Network names/passwords must match the router's supported configuration.
- Wrong-password and interrupted-setup recovery need further real-hardware testing.

## Українською

Застосунок допомагає налаштувати Wi-Fi старішого принтера Epson без WPS і додати мережевий принтер на Mac. Мову можна змінити в бічній панелі: **Мова → Українська**. Після налаштування принтер підключається до роутера самостійно; USB і постійно увімкнений Mac для друку не потрібні. AirPrint не додається до прошивки автоматично. Це тестова версія; неперевірені можливості не позначено як готові.

## Privacy and licensing

No telemetry, cloud print registration, router password storage, or public diagnostic uploads are implemented. Keep device captures and private logs out of issues and pull requests. See [SECURITY.md](SECURITY.md).

Our source is MIT licensed. Epson software is proprietary and governed by Epson's own terms; it is not part of this repository's licence and is not redistributed here. Trademarks belong to their respective owners.
