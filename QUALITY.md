# v5 quality gate

Target: an excellent all-in-one legacy Epson utility. A score of 100 is a target,
not a claim of completion. There is no verified v5 release yet.

Use this audit to drive implementation and regression testing:

| Area | Required evidence |
| --- | --- |
| First-use experience | Clean Mac: discover printer, obtain verified Epson components, complete authorization/licence steps, add queue and physically print through the app. No repeated setup prompts afterward. |
| Printer networking | USB setup without WPS, fresh scans, correct network selection, wrong password, interruption, router change and printer reboot. Mac not needed for printer's own Wi-Fi. |
| Daily use | PDF/photo preview and Epson paper/quality/color controls, clear queue selection, live pending jobs, cancellation scoped to the user's job, ink readings identified as cached when appropriate. |
| Care | Nozzle check, cleaning, cartridge replacement and alignment paths with correct model gating and physical verification. No automatic repeated cleaning. |
| Power | Read actual timer, apply correct model parameter, verify readback and persistence. Sleep and power-off remain distinct. |
| AirPrint | Opt-in Mac bridge, driver/queue readiness checks, one eligible host, healthy-host stability, failure detection, duplicate suppression, physical iPhone/iPad print and multi-Mac failover. No unsafe replay of stranded jobs. |
| UI/design | Coherent icon, dashboard and menu-bar popover; clear hierarchy, readable text, useful loading/empty/error states, restrained status updates and no contradictory instructions. |
| Accessibility/localization | Keyboard and screen-reader labels, English/Ukrainian layout checks, legible contrast and no color-only status meanings. |
| Recovery | Detect real faults and offer a relevant, verifiable repair. Explain physical steps and administrator/licence requirements accurately. Preserve working queues and network settings. |
| Delivery | Universal build, strict signature checks, clean source audit, public CI, checksums, Applications upgrade with fallback, documented compatibility and limitations. |
| Optional widget | Genuine WidgetKit extension, accurate update timestamps, credential-free shared data, desktop installation and behavior verified. |

Core checks, UI inspection and hardware tests are separate evidence. A passing
parser test is not a physical print test. A completed CUPS job is not a confirmed
paper result. A UI control without a verified protocol is not an implemented
hardware feature. Unfinished requirements carry forward across release numbers.

## Latest development pass (2026-10-22)

- 20 standalone core checks pass, including queue ownership, scan completion, host election and literal AirPrint job arguments.
- Universal arm64/x86_64 app and backend built; strict bundle verification and Ukrainian resource lint passed. Intel care diagnostics ran under Rosetta.
- Ukrainian menu preview inspected visually; toggling ink readings updates it immediately. AirPrint screen translated and inspected.
- Offline AirPrint correctly waits for printer readiness rather than advertising a usable print endpoint. Physical printer was unreachable during this pass.
- Bridge startup now uses a session generation to reject stale asynchronous work after shutdown. Approved network signature is persisted; other networks require deliberate enablement.
- Remaining AirPrint blockers include physical iOS output, multi-Mac failover, active-job handover/identity and advertised PostScript mismatch. See README.
