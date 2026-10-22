# Release completion goals

Requested scope: finish the v2 upgrade and continue through v5, with end-to-end verification at each release.
Completion means passing the acceptance checks below, not merely building the UI.

## v2

- [ ] Interactive English/Ukrainian setup and printer care, inspected in the running app.
- [ ] Fresh Wi-Fi scans wait for completion and reject failed/unknown responses.
- [ ] USB provisioning and network verification continue to work on the 1500W.
- [ ] Driver acquisition and Add to this Mac work, including a clean-Mac installation test.
- [ ] Maintenance commands are gated by driver capabilities, confirmed by the user, tracked as jobs, and physically verified.
- [ ] Include an interactive 1500W cartridge-replacement guide; separately verify whether software carriage-position control is supported before enabling it.
- [ ] Recovery handles failed scans, wrong passwords, interrupted USB and unavailable printers accurately.
- [ ] Automated core checks and universal build/signature checks pass.
- [ ] Install the tested version in Applications, preserving a fallback.
- [ ] Publish source, release artifact, checksums and honest compatibility notes on GitHub.

## v3

- [ ] Serve as the daily printer app: built-in PDF/photo printing with Epson driver options, print-job monitoring, inks, care, setup and diagnostics.
- [ ] Automatically detect printer/USB/LAN/driver/queue state and show actionable faults; verify each repair and never report an assumed fix as success.
- [ ] Repairs that consume ink, cancel jobs or change working network settings remain explicit user actions. Explain physical steps when software cannot fix the cause.
- [ ] Read the printer's power-off timer, apply supported settings and verify readback and persistence on hardware.
- [ ] Select among multiple connected printers; detect model capabilities without treating all legacy Epson devices as a 1500W.
- [ ] Broaden USB setup only for models with verified protocol and hardware evidence; publish a tested model matrix.
- [ ] Verify a working iPhone/iPad printing path. The user selected optional Mac-hosted AirPrint on 2026-10-22: any eligible Mac running this utility on the LAN may host, with one active bridge and takeover by another eligible Mac. Independent printer Wi-Fi remains the default and does not depend on the bridge.
- [ ] Verify bridge advertisement, network access boundaries, job routing, host availability, duplicate suppression and failover on physical iPhone/iPad hardware. Document that an unavailable/asleep host cannot bridge print jobs.
- [ ] Repeat end-to-end setup, reboot persistence, direct wireless printing and recovery checks with the release build.
- [ ] Complete English/Ukrainian UI review, accessibility review and documentation.
- [ ] Publish tested v3 source and redistributable release artifacts; install the tested build in Applications.

## Evidence already established

On one Epson Stylus Photo 1500W: USB network reads, Wi-Fi scanning, WPA2 setup without WPS, physical Wi-Fi printing with USB unplugged, and network return after a printer restart. Apple silicon was used for hardware tests. The baseline universal build also ran its Intel diagnostics under Rosetta; this is not a physical Intel Mac test.

The app does not store Wi-Fi passwords or require a Mac to remain on for the printer's own network connection. Native AirPrint, power writes, other-model USB writes and clean-machine installer continuation are not yet verified. Proprietary Epson components are acquired directly from Epson and are not included in public releases.

## v4 — daily use and recovery

- [ ] Complete the single-app daily workflow: printing, job control, ink readings, maintenance, router changes and repair guidance.
- [ ] Verify automatic device/driver/queue detection on a clean Mac, app restart, printer restart and network changes.
- [ ] Finish native menu-bar status and shortcuts, keyboard navigation, accessible labels and English/Ukrainian layout review.
- [ ] Replace the plain quick menu with a polished compact status popover: selected printer, reachability, available inks, printing/jobs/care actions, progress and actionable errors.
- [ ] Make every supported recovery action verifiable; distinguish a physical intervention from a software repair.

## v5 — polished release and optional desktop widget

- [ ] Carry every unresolved acceptance check above forward; version numbering does not waive unfinished requirements.
- [ ] Investigate and, when supported by build/signing tools, implement a genuine WidgetKit desktop extension with connection, available ink and job summaries plus app shortcuts.
- [ ] Widget data must exclude credentials, show its last update, and distinguish unavailable/cached status from fresh measurements.
- [ ] Verify extension installation and desktop behavior on a supported macOS version; do not substitute an ordinary app window for a widget.
- [ ] Complete a final clean-install, upgrade, direct printing, setup/recovery, accessibility, privacy and packaging audit; publish tested artifacts and update Applications.
