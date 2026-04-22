# RTC Relay Server Infrastructure — Artefacts

This repository accompanies our measurement study of commercial RTC relay
infrastructures ("RTC Relay Server Infrastructure Study", under submission).
It releases the three core artefacts of the project:

| Component | Path | Role |
|---|---|---|
| **Paper (technical report, extended)** | [`technical_report.pdf`](technical_report.pdf) | Full paper with appendices (relay IP/prefix tables for all four measurement targets and the per-call WhatsApp candidate list) that are omitted from the short workshop submission for space. |
| **VPN proxy + VM-side capture service** | [`vpn-proxy/`](vpn-proxy/) | Azure VM provisioning, WireGuard server setup, REST capture API (`api.py`), and the DPI pipeline that identifies relay IPs from RTP traffic (`check_dpi.py`, `check_dpi_same_host.py`, `lookupip.py`). Also contains the MacBook/Windows controller script (`rtc_capture.ps1`, `rtc_capture_mac.sh`) that orchestrates per-call capture across VMs. |
| **Mobile call-automation harness** | [`mobile-automation/`](mobile-automation/) | Xcode UI Test target (`ZoomDualUITests.swift`) that automates a host/client 1-on-1 call on two paired iPhones, flipping WireGuard tunnels between calls to sweep caller–callee region pairs. |

## End-to-end picture

```
┌───────────────────────────────────────────────────────────────────────┐
│  13 Azure VM regions (one VM per region) — deployed via vpn-proxy/   │
│    • WireGuard server (wg0, 10.8.0.0/24)                              │
│    • RTC capture REST API (api.py, port 5000)                         │
│    • tshark + DPI for relay IP extraction                             │
└──────────────┬────────────────────────────────┬───────────────────────┘
               │ WG tunnel                      │ WG tunnel
               ▼                                ▼
       ┌───────────────┐                ┌───────────────┐
       │ iPhone A      │                │ iPhone B      │
       │ host (caller) │ ── RTC call ─► │ client (callee)│
       │ Zoom/Discord/ │                │ Zoom/Discord/ │
       │ WhatsApp      │                │ WhatsApp      │
       └───────┬───────┘                └───────┬───────┘
               │ USB (Xcode UITest drives)       │ USB
               ▼                                ▼
       ┌───────────────────────────────────────────────┐
       │  MacBook controller: xcodebuild test          │
       │   + rtc_capture.ps1 / rtc_capture_mac.sh      │
       │   → per-region pair, 1-minute call, pcap pull │
       └───────────────────────────────────────────────┘
```

For each `(caller_region, callee_region)` pair in the sweep, the automation
harness enables the corresponding WireGuard tunnel on each phone, opens the
target RTC app, places a 1-minute call, and ends it — while the VM-side
capture service records all traffic on both endpoints. Post-processing on
the VMs extracts relay IPs from RTP flows and queries `ipinfo.io` for
geolocation; the captures themselves are archived for offline analysis
(see the paper).

## Reproducing the measurement

The three components are designed to be deployed roughly in the following order:

1. **Provision VMs and VPN.** Follow [`vpn-proxy/README.md`](vpn-proxy/README.md) to
   provision the 13 Azure VMs, install the capture service, and generate per-VM
   WireGuard phone configs.
2. **Provision phones.** Pair two iPhones to a MacBook via Xcode (*Developer Mode*
   on both), scan all 13 WireGuard QR codes into the WireGuard iOS app on each
   phone using the naming convention listed in both sub-READMEs.
3. **Configure the automation.** Edit the tunnel arrays and contact name at the
   top of [`mobile-automation/ZoomDualUITests/ZoomDualUITests.swift`](mobile-automation/ZoomDualUITests/ZoomDualUITests.swift).
4. **Run a campaign.** Start the capture API on both VMs
   (`systemctl start rtcproxy`), kick off the host and client UI-test targets
   (see the *Running a campaign* section in `mobile-automation/README.md`), and
   pull pcaps from the VMs when each pair finishes.
5. **Extract relays.** Post-process each pcap pair with
   `vpn-proxy/check_dpi.py` (WhatsApp/Discord) or the companion
   `run_dpi_zoom_v2.py` workflow described in the paper (Zoom-specific
   sustained-UDP-flow detection).

Per-sub-component setup instructions, dependencies, and operating notes are in
the respective `README.md` files.

## Anonymisation notice

This repository is released in conjunction with a double-blind submission.
Until the review period concludes, bibliographic references to the authors,
institutions, prior work, and private infrastructure have been stripped or
redacted. Path-like strings such as `C:\Users\USER\...` are placeholders the
user is expected to replace for their own environment; grant numbers and
personal contact names have been removed.

## License

Scripts and source files in this repository are released under the MIT
License unless a file-level header states otherwise. The accompanying
technical report is © the authors.
