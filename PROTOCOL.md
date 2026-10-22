# Protocol evidence and remaining work

## USB Wi-Fi configuration

The 1500W path uses Epson's signed XIOCBTm communication component and the
EPSON-XCTRL service. The app implements the IJCP configuration messages itself.
The request prefix is `WSDConfigReq:Operation` followed by ESC CR LF; successful
replies begin with `WSDRes:000` followed by ESC CR LF. The SOAP request and reply
parsers are in `USBConfiguration.swift`. USB transfer bounds and serialization
are enforced in `NativeUSB.m`.

The original setup application's scan conversion maps SSIDScan=1 to running,
SSIDScan=2 to finished successfully, and other values to failure. Fresh scans
wait for completion before reading SSIDList. This change has core parser checks;
the new polling sequence still needs a hardware retest.

## Maintenance

The installed 1500W driver advertises `Clean`, `PrintSelfTestPage`, and
`ReportLevels`, and a filter for `application/vnd.cups-command`. The app checks
these capabilities in the selected local queue and uses the documented
[CUPS command format](https://www.cups.org/doc/spec-command.html).

An ink-level request through the wireless queue reached the completed job state
in the v2 preview. Nozzle checks and cleaning still require physical validation.
An offline invocation of Epson's filter returned no output despite exit status
zero. Consequently filter exit status alone is not accepted as physical success.
The UI distinguishes submission, job completion and the physical printer result.
Commands are never retried automatically.

## Automatic power-off research

The installed model-specific UT1126 resource table gives these parameter values:

| UI option | Firmware parameter |
| --- | --- |
| Always on / automatic power-off disabled | 255 (0xFF) |
| 2 hours | 2 |
| 4 hours | 4 |
| 8 hours | 8 |
| 12 hours | 12 |

The read-command payload is `6F 74 02 00 01 00`. The set-command template is
`4F 54 03 00 00 00 00`, with the model's selected parameter placed in the final
byte. These values are reconstructed from installed resources and utility
control flow. The app's internal Always on enum value 0 must **not** be sent
directly as a firmware parameter.

Transport framing, response validation and persistence are not hardware verified.
The app intentionally leaves power writes unavailable until read/write/readback
tests establish the complete protocol. No firmware image has been flashed.

## Research boundaries

Other model profiles are discovery/driver mappings, not evidence of compatible
USB writes. Enable a model only after verifying its capabilities, transport,
responses and physical behavior. Public releases contain our code and artwork;
Epson components are obtained from official sources under their own terms.
