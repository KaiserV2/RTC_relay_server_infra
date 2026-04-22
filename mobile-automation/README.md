# Mobile RTC Call Automation (Xcode UI Tests)

This component automates **one-to-one RTC calls between two physical iPhones** so that call-level measurements can be issued at scale across many `(caller-VPN-region, callee-VPN-region)` pairs without a human in the loop.

The automation is implemented as **Xcode UI Tests** (`XCUITest`) that drive the iOS system Settings app (to toggle WireGuard VPN tunnels) and the target RTC application (to place and answer calls). Each iPhone runs its own test target: the **host** phone places outbound calls; the **client** phone answers them. The two targets are coordinated externally (the MacBook controller starts both UI test runs; each iPhone loops over its own list of VPN tunnels).

The reference implementation in this repository targets the **Zoom iOS client** (bundle ID `us.zoom.videomeetings`). The Discord and WhatsApp automation flows used in the paper follow the same architecture with app-specific selector updates; they are not released here because (a) they are thin adaptations of the same loop and (b) the selectors drift with every app update, so a static release has limited reuse value.

---

## Why Xcode UI Tests (and not a WebDriver-style framework)

We evaluated three candidate frameworks before settling on XCUITest:

| Framework | Pros | Why we did not use it |
|---|---|---|
| **Appium / WebDriverAgent** | Cross-platform, scriptable from Python | On iOS it still compiles and signs a `WebDriverAgentRunner.app`; effectively the same signing workflow as a native UI test but with a Python indirection layer. |
| **Apple Configurator / MDM** | Enterprise-scale | Cannot express per-call UI flows (tap contact, tap Join, wait, end call). |
| **XCUITest (chosen)** | First-party; full access to `XCUIElement` queries, `XCUIApplication(bundleIdentifier:)` to drive *other* apps, and `XCUIDevice` for volume/orientation | Requires Xcode and per-device pairing; Swift-only. |

XCUITest is the only option that can (i) drive third-party apps via their bundle IDs, (ii) drive the system **Settings → VPN** pane to flip WireGuard tunnels, and (iii) dismiss system alerts (via the `com.apple.springboard` bundle) — all three are needed for this measurement.

---

## Repository layout

```
mobile-automation/
├── README.md                              ← this file
├── wireguardZoomAutomation.xcodeproj/     ← Xcode project (stub host app + test targets)
├── wireguardZoomAutomation.xctestplan     ← test plan (controls parallelism, env vars)
├── wireguardZoomAutomation/               ← stub "app under test" (a placeholder iOS app)
│   ├── wireguardZoomAutomationApp.swift
│   ├── ContentView.swift
│   ├── Item.swift
│   └── Assets.xcassets/
├── wireguardZoomAutomationTests/          ← (unused) unit-test target placeholder
├── wireguardZoomAutomationUITests/        ← (unused) UITest target scaffolding
│   ├── wireguardZoomAutomationUITests.swift
│   └── wireguardZoomAutomationUITestsLaunchTests.swift
└── ZoomDualUITests/
    └── ZoomDualUITests.swift              ← the actual host/client automation
```

The stub `wireguardZoomAutomation` app is present only because Xcode UI test targets must be attached to an "app under test"; the app itself is never used. All runnable logic lives in `ZoomDualUITests/ZoomDualUITests.swift`.

---

## End-to-end architecture

```
┌─────────────────────────┐              ┌─────────────────────────┐
│   MacBook (controller)  │              │   MacBook (controller)  │
│   xcodebuild test        │              │   xcodebuild test        │
│   -destination id=HOST   │              │   -destination id=CLIENT │
└────────────┬────────────┘              └────────────┬────────────┘
             │ USB                                    │ USB
             ▼                                        ▼
      ┌───────────┐                           ┌───────────┐
      │  iPhone A │                           │  iPhone B │
      │  (caller) │                           │ (callee)  │
      ├───────────┤                           ├───────────┤
      │ WireGuard │◄─── VPN tunnel ─────►     │ WireGuard │
      │  Settings │     (to Azure VM in       │  Settings │
      │           │      region X, Y, ...)    │           │
      ├───────────┤                           ├───────────┤
      │   Zoom    │◄── 1-on-1 call ─► relay   │   Zoom    │
      └───────────┘                           └───────────┘
```

For each entry in the iPhone's tunnel list, the UI test enables the tunnel in **Settings → VPN**, launches Zoom, runs the **Host** or **Client** flow, ends the call, and disables the tunnel before moving to the next region.

Trace capture is performed at the Azure VM (see `../vpn-proxy/`), not on the phone, so the automation code does not need to handle pcaps.

---

## Host and client flows

### Host (`testHost_RunAllTunnels`)
For each tunnel in `hostTunnels`:
1. **VPN ON**: open `Settings → VPN`, locate the row whose label matches the tunnel name, tap it, flip the switch, and wait for iOS to finish setting up the tunnel.
2. **Launch Zoom** via `XCUIApplication(bundleIdentifier: "us.zoom.videomeetings")`.
3. Dismiss any first-run audio prompts (`Use Internet Audio`, `Call using Internet Audio`).
4. Tap the **Meet** tab.
5. Tap **Start a meeting**.
6. Tap **Participants → (+) → Invite contacts**.
7. Select the contact whose `displayName == contactName`.
8. Tap the **Invite** button in the nav bar.
9. When the callee joins the waiting room, tap **Admit** (handled in two branches: (i) a springboard-level alert, (ii) an `Admit` button inside the participants list).
10. Hold the call for `callSecondsHost` seconds (default 20s — long enough for RTP to stabilize and for our VM-side capture to accumulate packets).
11. End the meeting via `End → End meeting for all`.
12. **VPN OFF**.

### Client (`testClient_RunAllTunnels`)
For each tunnel in `clientTunnels`:
1. **VPN ON**.
2. Launch Zoom.
3. Wait up to 30 seconds for the in-app **Join** card to appear. Multiple UI elements in the Zoom client are labelled "Join" (the tab bar has one, the incoming-call card has another); `tapJoinButton()` disambiguates by picking the **visible**, **hittable**, and **largest-area** `Join` element, which is consistently the incoming-call card.
4. Hold the call for `callSecondsClient` seconds.
5. Terminate Zoom via `app.terminate()`.
6. **VPN OFF**.

---

## Configuration

The three things you must edit before running are all at the top of `ZoomDualUITests/ZoomDualUITests.swift`:

```swift
// 1. Callee contact name on the host phone's Zoom contact list.
//    Must match exactly (case-sensitive, including middle names).
private let contactName = "REPLACE_WITH_CALLEE_CONTACT_NAME"

// 2. WireGuard tunnel names exactly as they appear in iOS Settings → VPN.
//    These must match the tunnel labels you picked when you scanned the
//    WireGuard QR codes from the VM (see ../vpn-proxy/README.md).
private let hostTunnels:   [String] = ["rtc-australia-east"]
private let clientTunnels: [String] = ["rtc-central-us", "rtc-japan-east", "rtc-central-india"]

// 3. Call duration per tunnel (seconds).
private let callSecondsClient = 20
private let callSecondsHost   = 20
```

The canonical tunnel names used in our measurements are:

```
rtc-east-us           rtc-central-us          rtc-west-us
rtc-south-central-us  rtc-chile-central       rtc-uk-south
rtc-poland-central    rtc-uae-north           rtc-japan-east
rtc-central-india     rtc-south-africa-north  rtc-australia-east
rtc-malaysia-west
```

---

## Setup from scratch

### 1. Xcode project
Open `wireguardZoomAutomation.xcodeproj` in Xcode **15.0** or newer. The project is configured for **iOS 18.4** deployment target (adjust under *General → Deployment Info* if your devices run an older iOS).

### 2. Signing
In *Signing & Capabilities*, assign a valid Apple Developer team to all three targets:
- `wireguardZoomAutomation` (app)
- `wireguardZoomAutomationTests` (unit tests — unused but must compile)
- `wireguardZoomAutomationUITests` and/or `ZoomDualUITests` (UI tests — this is the one that actually runs)

A free Apple ID works for development builds on a single paired device; an enrolled team is required to run on multiple phones without 7-day re-signing.

### 3. Pair each iPhone
1. Connect the iPhone via USB.
2. On the phone: *Settings → Privacy & Security → Developer Mode → ON* (iOS 16+ requires a restart).
3. Trust the Mac when prompted.
4. In Xcode: *Product → Destination → Manage Run Destinations…* → verify both phones appear.

### 4. Provision Zoom on both phones
- Install Zoom from the App Store on both phones.
- Sign in. The free tier is sufficient for 1-on-1 calls.
- Open Zoom once manually to dismiss first-run permission prompts for camera, microphone, notifications, and contacts.
- On the **host** phone, add the callee as a Zoom contact. The `contactName` constant in the test file must match this contact's display name **exactly**.

### 5. Install WireGuard tunnels on both phones
Follow `../vpn-proxy/README.md` to provision the 13 Azure VMs and generate per-VM phone configs. Scan each VM's QR code **on the appropriate phone** (caller QRs → host phone; callee QRs → client phone). Name each tunnel in the WireGuard iOS app exactly as it appears in the tunnel arrays above.

### 6. One-time iOS convenience settings
- *Settings → Display & Brightness → Auto-Lock → Never* (prevents the screen from locking mid-run).
- Disable DND and Focus modes for the duration of the campaign (iOS suppresses the incoming-call banner otherwise).

---

## Running a campaign

There are two execution paths:

### A. Interactive (single campaign, from the Xcode GUI)

1. Open **Test Navigator** (⌘6).
2. On the **host phone**: set the Xcode destination to that phone, click the ◇ next to `testHost_RunAllTunnels()`.
3. On the **client phone**: open a second Xcode window (⌘N if needed) or switch destination, click the ◇ next to `testClient_RunAllTunnels()`.
4. The host should start slightly before the client so that the Zoom meeting exists when the client tries to join.

### B. Scripted (measurement campaigns, from the Mac controller)

From a MacBook shell, drive both phones in parallel:

```bash
# In one terminal (host)
xcodebuild test \
  -project wireguardZoomAutomation.xcodeproj \
  -scheme wireguardZoomAutomation \
  -destination 'platform=iOS,id=<HOST_UDID>' \
  -only-testing:ZoomDualUITests/ZoomDualUITests/testHost_RunAllTunnels

# In a second terminal (client), started ~5s after host
xcodebuild test \
  -project wireguardZoomAutomation.xcodeproj \
  -scheme wireguardZoomAutomation \
  -destination 'platform=iOS,id=<CLIENT_UDID>' \
  -only-testing:ZoomDualUITests/ZoomDualUITests/testClient_RunAllTunnels
```

UDIDs come from `xcrun devicectl list devices` (Xcode 15+) or `idevice_id -l`.

The `.xctestplan` file in the repo has `executeInParallel = false` for the UITests target; this ensures ⌘U runs tests deterministically on a single destination. Remove the override if you prefer ⌘U to fan out to both connected phones automatically.

Logs and screenshots are written to Xcode's derived data directory per run (`~/Library/Developer/Xcode/DerivedData/<project-hash>/Logs/Test/`). Each test run produces an `.xcresult` bundle that Xcode can replay visually.

---

## Adapting to other RTC applications

The flow is structurally identical for any RTC app; only the selectors change. To add a new app:

1. Duplicate `ZoomDualUITests.swift` to `<App>DualUITests.swift`.
2. Change `zoomBundleId` to the target app's bundle ID. Common ones:
   - Discord: `com.hammerandchisel.discord`
   - WhatsApp: `net.whatsapp.WhatsApp`
   - Microsoft Teams: `com.microsoft.skype.teams`
   - Google Meet: `com.google.Meet`
3. Rewrite `hostFlow()` and `clientFlow()` to match the target app's UI. The easiest way to discover selectors is to run an empty UI test with a `po app.debugDescription` in the Xcode debugger while the target app is foregrounded — this prints the full accessibility tree, from which stable `label`, `identifier`, or `staticText` matches can be picked.
4. The VPN helpers (`vpnOpenPane`, `vpnSelectTunnel`, `vpnSetTunnel`, `vpnHandleSystemAlerts`) are app-agnostic and can be reused as-is.

---

## Known caveats and limitations

UI automation against commercial RTC apps is inherently fragile; we document the failure modes we observed during the measurement campaign so that re-running this code yields predictable results rather than surprises.

- **App version drift.** The selector strings in `ZoomDualUITests.swift` are stable against Zoom iOS 5.17.x–5.19.x. Major UI redesigns (e.g., Zoom changing the "Meet" tab label) require re-auditing the selector queries. When in doubt, pause the test in the Xcode debugger and call `po app.buttons.allElementsBoundByIndex.map { $0.label }` to re-enumerate live labels.
- **"Join" disambiguation.** Multiple Zoom UI elements carry the label `Join`. `tapJoinButton()` picks the largest-area hittable one; if Zoom's future UI introduces another large `Join` element (e.g., a full-screen modal), the heuristic may select the wrong one. Replacing the area-based tiebreaker with an explicit `identifier` match is a safer long-term fix if Zoom exposes accessibility identifiers on that card.
- **iOS consent dialogs.** On first run of the VPN toggle, iOS shows *"rtcproxy Would Like to Add VPN Configurations"*; `vpnHandleSystemAlerts()` covers `Allow / OK / Continue / Close` buttons, but new iOS releases occasionally introduce new labels. Add to the list in `vpnHandleSystemAlerts()` if you see the test stall on a first run.
- **Client startup race.** The client flow waits up to 30s for the Join card; if the client enables its VPN faster than Zoom finishes signing the host in, the card never appears. Add `sleep(5)` as the first line of `clientFlow()` if you see sporadic "Failed to tap the correct Join button" failures — this gives the host time to issue the invite before the client starts polling.
- **Zoom background state.** If Zoom is killed by iOS (e.g., memory pressure) while a call is ringing, the incoming-call banner is owned by SpringBoard, not Zoom, and `XCUIApplication(bundleIdentifier: zoomBundleId)` cannot query it. The test relaunches Zoom at the start of every iteration (`app.terminate(); app.launch()`) to avoid starting from an ambiguous state.
- **Multi-phone parallel runs via `⌘U`.** Xcode's default behaviour with two destinations is to run the same test on both. This repo's `.xctestplan` disables that by setting `executeInParallel = false`; use Option B above (two `xcodebuild test` invocations with explicit `-destination id=...`) if you want true per-phone test selection.
- **Auto-lock / Always-On display.** Do not use Always-On display with StandBy mode during runs — StandBy swallows taps on the Join card. Temporarily set Auto-Lock to *Never*.
- **Free Apple ID signing.** A free developer account limits you to one paired device and re-signs expire after 7 days, breaking long campaigns. Enrol in the Apple Developer Program ($99/yr) before starting multi-week data collection.

---

## Citing and reusing

If you build on this automation harness, please cite the accompanying paper and the referenced VPN-proxy component in `../vpn-proxy/`. The automation scripts are research artefacts: they are provided as a concrete, reproducible starting point, not as a maintained product. Open an issue before building large campaigns on top of this code so we can flag known drift against the current app versions.
