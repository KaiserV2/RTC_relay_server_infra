// ZoomDualUITests.swift — Host/Client flows + robust VPN control + per-VM loops
// Host: for each host tunnel → VPN ON → Zoom host flow → VPN OFF
// Client: for each client tunnel → VPN ON → Zoom client flow → VPN OFF
//
// Host flow (strict):
//   Meet → Start a meeting → wait 2s → Participants → (+) Invite contacts → select contact → Invite
//   → Admit (popup OR row) → wait 20s → Participants → End (top-right) → End meeting for all
//
// Client flow:
//   Wait for in-app "Join" card → tap correct red "Join" → wait 20s → terminate

import XCTest
import CoreGraphics

final class ZoomDualUITests: XCTestCase {
    // MARK: - App IDs
    private let zoomBundleId     = "us.zoom.videomeetings"
    private let settingsBundleId = "com.apple.Preferences"

    // MARK: - Test constants
    // Replace with the callee's exact contact name as it appears in the host phone's Zoom contact list.
    private let contactName       = "REPLACE_WITH_CALLEE_CONTACT_NAME"
    private let callSecondsClient = 20
    private let callSecondsHost   = 20

    // MARK: - Tunnels (edit these lists as needed)
    private let hostTunnels:   [String] = ["rtc-australia-east"]
    private let clientTunnels: [String] = ["rtc-central-us","rtc-japan-east","rtc-germany-west-central"]

    // MARK: - XCTest
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Public tests (loop over VMs)
    func testHost_RunAllTunnels() {
        for tunnel in hostTunnels {
            vpnOpenPane()
            vpnSelectTunnel(named: tunnel)
            vpnSetTunnel(named: tunnel, enabled: true)

            let app = launchZoom()
            hostFlow(on: app)

            vpnOpenPane()
            vpnSelectTunnel(named: tunnel)
            vpnSetTunnel(named: tunnel, enabled: false)
        }
    }

    func testClient_RunAllTunnels() {
        for tunnel in clientTunnels {
            vpnOpenPane()
            vpnSelectTunnel(named: tunnel)
            vpnSetTunnel(named: tunnel, enabled: true)

            let app = launchZoom()
            clientFlow(on: app)

            vpnOpenPane()
            vpnSelectTunnel(named: tunnel)
            vpnSetTunnel(named: tunnel, enabled: false)
        }
    }

    // MARK: - Host flow
    private func hostFlow(on app: XCUIApplication) {
        // Clear audio prompts that can look like Join
        _ = tapIfExists(app.buttons["Use Internet Audio"], within: 1)
        _ = tapIfExists(app.buttons["Call using Internet Audio"], within: 1)
        _ = tapIfExists(app.buttons["Use device audio"], within: 1)

        // Meet tab
        tapAnyLabel(["Meet", "Meet & Chat", "Meet & chat"],
                    in: app.buttons, timeout: 8,
                    failureMsg: "Failed to open Meet tab")

        // Start a meeting
        tapAnyLabel(["Start a meeting", "Start a Meeting", "Start"],
                    in: app.buttons, timeout: 8,
                    failureMsg: "Failed to tap Start a meeting")

        // Settle to avoid hitting calendar tiles
        sleep(2)

        // Ensure controls visible
        revealControls(in: app)
        usleep(200_000)

        // Participants
        openParticipants(in: app)
        sleep(2)

        // (+) Invite
        openInviteFromParticipants(in: app)

        // Invite contacts
        if !(tapIfExists(app.buttons["Invite contacts"], within: 3.0) ||
             tapIfExists(app.buttons["Invite Contacts"], within: 3.0)) {
            let ic1 = app.cells.staticTexts["Invite contacts"]
            let ic2 = app.cells.staticTexts["Invite Contacts"]
            if ic1.waitForExistence(timeout: 2) { ic1.tap() }
            else if ic2.waitForExistence(timeout: 2) { ic2.tap() }
            else { XCTFail("Invite contacts not found"); return }
        }

        // Contacts list load
        sleep(2)

        // Select contact & Invite
        let contactCell = app.cells.staticTexts[contactName]
        XCTAssertTrue(contactCell.waitForExistence(timeout: 8), "Contact '\(contactName)' not found")
        contactCell.tap()
        usleep(300_000)

        if !(tapIfExists(app.navigationBars.buttons["Invite"], within: 5.0)) {
            let altInvite = app.navigationBars.buttons.element(boundBy: 1)
            XCTAssertTrue(altInvite.exists, "Invite nav button not found")
            altInvite.tap()
        }

        // Admit
        admit(contact: contactName, in: app)

        // Keep call alive
        sleep(UInt32(callSecondsHost))

        // Per your exact ask: Participants → End → End meeting for all
        openParticipants(in: app)                       // brings focus to bottom ribbon context
        _ = tapIfExists(app.buttons["Close"], within: 1.0) // close panel if visible
        revealControls(in: app)
        XCTAssertTrue(
            tapIfExists(app.buttons["End"], within: 3.0) ||
            tapIfExists(app.navigationBars.buttons["End"], within: 3.0),
            "Failed to find 'End' button to confirm meeting termination."
        )
        confirmEndMeeting(in: app)
    }

    // MARK: - Client flow
    private func clientFlow(on app: XCUIApplication) {
        // Optional startup delay: uncomment if the client's VPN comes up faster
        // than the host finishes issuing the invite (see README, "Client-side startup delay").
        // sleep(5)

        // Disambiguate multiple "Join" buttons: pick the visible, largest-area one
        XCTAssertTrue(tapJoinButton(in: app, timeout: 30.0), "Failed to tap the correct 'Join' button on client.")
        sleep(UInt32(callSecondsClient))
        app.terminate()
    }

    // MARK: - Client "Join" disambiguation
    @discardableResult
    private func tapJoinButton(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let joinPred      = NSPredicate(format: "label ==[c] 'Join'")
        let containsPred  = NSPredicate(format: "label CONTAINS[c] 'join'")
        let joinQueries: [XCUIElementQuery] = [
            app.buttons.matching(joinPred),
            app.buttons.matching(containsPred)
        ]

        while Date() < deadline {
            for q in joinQueries {
                let cnt = q.count
                if cnt == 1 {
                    let btn = q.firstMatch
                    if btn.exists && btn.isHittable { btn.tap(); return true }
                } else if cnt > 1 {
                    var candidates = [XCUIElement]()
                    for i in 0..<cnt {
                        let e = q.element(boundBy: i)
                        if e.exists && e.isHittable { candidates.append(e) }
                    }
                    if candidates.isEmpty {
                        revealControls(in: app)
                        usleep(200_000)
                    } else {
                        let best = candidates.max {
                            let a0 = $0.frame.width * $0.frame.height
                            let a1 = $1.frame.width * $1.frame.height
                            if a0 == a1 { return $0.frame.midY < $1.frame.midY }
                            return a0 < a1
                        }
                        best?.tap(); return true
                    }
                }
            }
            revealControls(in: app)
            usleep(250_000)
        }

        let anyJoin = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] 'Join'")).firstMatch
        if anyJoin.exists && anyJoin.isHittable { anyJoin.tap(); return true }
        return false
    }

    // MARK: - End confirmation
    private func confirmEndMeeting(in app: XCUIApplication) {
        // brief delay for action sheet animation
        usleep(400_000)
        let candidates = [
            "End meeting for all",
            "End Meeting for All",
            "End for All",
            "End meeting for all participants",
            "End Meeting"
        ]
        for label in candidates {
            if tapIfExists(app.buttons[label], within: 3.0) { return }
        }
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            let buttons = sheet.buttons.allElementsBoundByIndex
            if let first = buttons.first { first.tap(); return }
        }
        XCTFail("Could not find End meeting confirmation")
    }

    // MARK: - Admit
    private func admit(contact name: String, in app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) {
            if alert.buttons["Admit"].exists { alert.buttons["Admit"].tap(); return }
            if alert.buttons["View"].exists { alert.buttons["View"].tap(); usleep(300_000) }
        }

        openParticipants(in: app); usleep(300_000)

        let cell = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 8), "Participants cell for '\(name)' not found")

        if cell.buttons["Admit"].exists && cell.buttons["Admit"].isHittable { cell.buttons["Admit"].tap(); return }
        if cell.staticTexts["Admit"].exists && cell.staticTexts["Admit"].isHittable { cell.staticTexts["Admit"].tap(); return }

        let allAdmits = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] 'Admit'"))
        XCTAssertTrue(allAdmits.count > 0, "No 'Admit' elements found at all")

        let cellY = cell.frame.midY
        var best: XCUIElement?
        var bestDy = CGFloat.greatestFiniteMagnitude
        for i in 0..<allAdmits.count {
            let e = allAdmits.element(boundBy: i)
            guard e.exists else { continue }
            let dy = abs(e.frame.midY - cellY)
            if dy < bestDy { bestDy = dy; best = e }
        }
        guard let best = best else { XCTFail("Could not choose a unique 'Admit'"); return }
        best.tap()
    }

    // MARK: - Zoom helpers
    private func launchZoom() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: zoomBundleId)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12), "Zoom failed to foreground")
        sleep(1)
        return app
    }

    private func revealControls(in app: XCUIApplication) {
        let win = app.windows.firstMatch
        if win.exists { win.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    private func openParticipants(in app: XCUIApplication) {
        if tapIfExists(app.buttons["Participants"], within: 2.0) { return }

        let labelPred = NSPredicate(format: "label BEGINSWITH[c] 'Participants'")
        let participantsMatch = app.descendants(matching: .any).matching(labelPred).firstMatch
        if participantsMatch.waitForExistence(timeout: 2.0) { participantsMatch.tap(); return }

        if tapIfExists(app.buttons["icon participant normal"], within: 1.0) { return }

        let win = app.windows.firstMatch
        XCTAssertTrue(win.waitForExistence(timeout: 2.0), "Main window missing")
        let nearBottom = win.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.92))
        nearBottom.tap()

        _ = app.staticTexts["Participants"].waitForExistence(timeout: 3.0)
            || app.buttons["Close"].waitForExistence(timeout: 2.0)
            || app.staticTexts["Waiting room"].waitForExistence(timeout: 2.0)
    }

    private func openInviteFromParticipants(in app: XCUIApplication) {
        if tapIfExists(app.buttons["Add Participants"], within: 1.0) { return }
        if tapIfExists(app.buttons["Invite Participants"], within: 1.0) { return }
        if tapIfExists(app.buttons["Invite"], within: 1.0) { return }

        let plus = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '+' OR label CONTAINS[c] 'add'")).firstMatch
        if plus.exists { plus.tap(); return }

        let more = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More' OR label == '…'")).firstMatch
        if more.exists { more.tap(); return }

        let nbBtn = app.navigationBars.buttons.element(boundBy: 1)
        if nbBtn.exists { nbBtn.tap(); return }

        XCTFail("Could not open Invite sheet from Participants")
    }

    private func tapAnyLabel(_ labels: [String],
                             in query: XCUIElementQuery,
                             timeout: TimeInterval,
                             failureMsg: String) {
        for label in labels {
            let e = query[label]
            if e.waitForExistence(timeout: 1.2) { e.tap(); return }
        }
        if let key = labels.first?.split(separator: " ").first {
            let pred = NSPredicate(format: "label CONTAINS[c] %@", String(key))
            let e = query.matching(pred).firstMatch
            if e.waitForExistence(timeout: timeout) { e.tap(); return }
        }
        XCTFail(failureMsg)
    }

    @discardableResult
    private func tapIfExists(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        if element.waitForExistence(timeout: timeout) { element.tap(); return true }
        return false
    }

    // MARK: - VPN helpers (Settings → VPN pane → select tunnel → toggle)
    /// Open the Settings app and land on the VPN list pane.
    private func vpnOpenPane() {
        // Terminate test host app context to avoid conflicts
        XCUIApplication().terminate()

        let settings = XCUIApplication(bundleIdentifier: settingsBundleId)
        settings.terminate()
        settings.launch()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), "Settings failed to launch")

        // Give UI time to lay out (helps with slower devices)
        sleep(2)

        // Try direct VPN cell on main table
        if settings.cells["VPN"].waitForExistence(timeout: 2) {
            settings.cells["VPN"].tap()
            sleep(1)
            return
        }

        // Try label contains VPN (localized or variant)
        let vpnPredicate = NSPredicate(format: "label CONTAINS[c] 'VPN'")
        let vpnCell = settings.cells.containing(vpnPredicate).firstMatch
        if vpnCell.waitForExistence(timeout: 2) {
            vpnCell.tap()
            sleep(1)
            return
        }

        // Fallback: scan all cells
        let cells = settings.cells.allElementsBoundByIndex
        for cell in cells where cell.label.localizedCaseInsensitiveContains("vpn") {
            cell.tap()
            sleep(1)
            return
        }

        XCTFail("VPN cell not found on main Settings screen")
    }

    /// On the VPN list screen, tap the row that matches `tunnelName`
    private func vpnSelectTunnel(named tunnelName: String) {
        let settings = XCUIApplication(bundleIdentifier: settingsBundleId)
        sleep(1) // small settle

        // Direct match
        var cell = settings.cells[tunnelName]
        if !cell.exists {
            // Contains match
            let pred = NSPredicate(format: "label CONTAINS[c] %@", tunnelName)
            cell = settings.cells.containing(pred).firstMatch
        }
        if !cell.exists {
            // Scroll & search
            let all = settings.cells.allElementsBoundByIndex
            if let found = all.first(where: { $0.label.localizedCaseInsensitiveContains(tunnelName) }) {
                cell = found
            }
        }

        XCTAssertTrue(cell.waitForExistence(timeout: 8), "Tunnel '\(tunnelName)' not found in VPN list")
        if !cell.isHittable { settings.swipeUp(); usleep(300_000) }
        cell.tap()
        sleep(1)
        vpnHandleSystemAlerts()
    }

    /// Toggle the tunnel switch to `enabled`
    private func vpnSetTunnel(named tunnelName: String, enabled: Bool) {
        let settings = XCUIApplication(bundleIdentifier: settingsBundleId)

        let tunnelSwitch = settings.switches.firstMatch
        XCTAssertTrue(tunnelSwitch.waitForExistence(timeout: 8), "Tunnel switch not found for \(tunnelName)")

        let current = (tunnelSwitch.value as? String) ?? ""
        let isOn = current == "1" || current.lowercased() == "on"

        if enabled != isOn {
            tunnelSwitch.tap()
            vpnHandleSystemAlerts()
            // Give iOS network stack a moment (longer on connect)
            sleep(enabled ? 6 : 2)
        }

        // Navigate back to VPN list if a back button exists
        let back = settings.navigationBars.buttons.firstMatch
        if back.exists { back.tap(); usleep(300_000) }
    }

    /// Dismiss common system alerts that can block toggling
    private func vpnHandleSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Continue", "Close"] {
            if springboard.buttons[label].waitForExistence(timeout: 1.0) {
                springboard.buttons[label].tap()
                usleep(300_000)
            }
        }
    }
}

