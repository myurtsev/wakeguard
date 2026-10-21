import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let client = LeaseClient()
    private let defaults = UserDefaults.standard
    private var settings = WakeSettings()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panelController: NSHostingController<WakePanelView>!
    private let helperSetup = HelperSetup()
    private var activityWindow: ActivityWindowController?
    private var pluginsWindow: PluginsWindowController?
    private lazy var plugins = PluginManager()
    private var summaryWindow: SummaryWindowController?
    private var history: AuditHistory?
    private var lastReadSummaryID: String?
    private var observedSummaryBaseline = false
    private var claudeConnected = false
    private var timer: Timer?
    private var status: HelperStatus?
    private var generation: String?
    private var session: String?
    private var sequence: UInt64 = 0
    private var startedAt = 0.0
    private var localReason: String?
    private var uninstallPending = false
    private var startedUninstallAt = 0.0
    private var untilAgents = false
    private var agentWaiter = AgentWaiter()
    private var agentSnapshot = AgentSnapshot(unknownSources: 1)
    private let codexReader = CodexActivityReader()
    private var claudeReader = ClaudeActivityReader()
    private let agentQueue = DispatchQueue(label: "nl.local.WakeGuard.agent-status")
    private var agentReadPending = false
    private var lastAgentRead = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: WakePaths.bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        untilAgents = defaults.bool(forKey: "untilAgents")
        if let data = defaults.data(forKey: "settings"),
           let stored = try? JSONDecoder().decode(WakeSettings.self, from: data),
           [20, 30, 40].contains(stored.batteryFloor),
           [0, 30, 60, 120].contains(stored.sessionMinutes) {
            settings = stored
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "WakeGuard: Off")
        statusItem.button?.image?.isTemplate = true
        panelController = NSHostingController(rootView: WakePanelView(state: PanelState(), actions: panelActions()))
        panelController.sizingOptions.insert(.preferredContentSize)
        popover.contentViewController = panelController
        popover.behavior = .transient
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: .leftMouseDown)
        claudeConnected = (try? ClaudeHooks.isEnabled()) ?? defaults.bool(forKey: "claudeConnected")
        plugins.onChange = { [weak self] in self?.updateMenu() }
        tick()
        let timer = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if (status?.protocolVersion ?? 0) < WakePaths.helperProtocol {
            DispatchQueue.main.async { self.togglePanel() }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        tick()
        popover.contentSize = panelController.view.fittingSize
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        popover.close()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func panelActions() -> PanelActions {
        PanelActions(main: { [weak self] in self?.toggleSession() },
            mode: { [weak self] value in
                guard let self, value != self.untilAgents else { return }
                self.toggleAgentMode()
            },
            ac: { [weak self] value in self?.settings.onAC = value; self?.persist() },
            battery: { [weak self] value in self?.settings.onBattery = value; self?.persist() },
            darken: { [weak self] value in self?.settings.darkenDisplays = value; self?.persist() },
            login: { [weak self] _ in self?.toggleLogin() },
            floor: { [weak self] value in
                guard [20, 30, 40].contains(value) else { return }
                self?.settings.batteryFloor = value; self?.persist()
            },
            duration: { [weak self] value in
                guard [0, 30, 60, 120].contains(value) else { return }
                self?.settings.sessionMinutes = value; self?.persist()
            },
            claude: { [weak self] value in self?.configureClaude(enabled: value) },
            setup: { [weak self] in self?.openInstaller() },
            uninstall: { [weak self] in self?.uninstall() },
            about: { [weak self] in self?.showAbout() },
            quit: { [weak self] in self?.quit() },
            activity: { [weak self] in self?.showActivity() },
            plugins: { [weak self] in self?.showPlugins() })
    }

    @objc private func tick() {
        pollAgents()
        do {
            let previouslyUnavailable = status == nil
            let snapshot = try client.status()
            status = snapshot
            if uninstallPending {
                let elapsed = Date().timeIntervalSince1970 - startedUninstallAt
                if snapshot.generation != generation {
                    uninstallPending = false
                    disarm("System helper restarted; removal incomplete. Try again.")
                } else if snapshot.mode == "error" {
                    uninstallPending = false
                    disarm(snapshot.reason)
                } else if elapsed >= 10 || (snapshot.mode == "off" && elapsed >= 5) {
                    uninstallPending = false
                    disarm("Removal unconfirmed. Reinstall the system helper and try again.")
                } else {
                    localReason = snapshot.owned ? "Restoring normal sleep…" : "Removing system helper…"
                }
            } else if let session {
                if snapshot.generation != generation {
                    disarm("System helper restarted; start again")
                } else if snapshot.session == session && (snapshot.mode == "error" || snapshot.mode == "stopped") {
                    disarm(snapshot.reason)
                } else if snapshot.session != session && Date().timeIntervalSince1970 - startedAt >= 4 {
                    disarm("Session unconfirmed; start again")
                } else {
                    try send(enabled: true)
                }
            } else if previouslyUnavailable {
                localReason = nil
            }
        } catch {
            status = nil
            if uninstallPending {
                uninstallPending = false
                if !FileManager.default.fileExists(atPath: WakePaths.directory) {
                    disarm("System helper removed")
                } else {
                    disarm("Removal unconfirmed. Reinstall the system helper and try again.")
                }
            } else {
                disarm(error.localizedDescription)
            }
        }
        refreshHistory()
        updateMenu()
    }

    private func updateMenu() {
        let active = session != nil
        let agents = currentAgents()
        let setupNeeded = status == nil || (status?.protocolVersion ?? 0) < WakePaths.helperProtocol
        let installing = helperSetup.isInstalling
        let canStart = !setupNeeded && status?.mode != "error" && status?.owned == false
        let agentStartAllowed = !untilAgents || (agents.activeCount > 0 && agents.unknownCount == 0)
        let mode = status?.mode ?? "off"
        let label: String
        switch mode {
        case "awake": label = "Awake"
        case "paused": label = "Paused"
        case "error": label = "Recovery required"
        case "stopped": label = "Stopped"
        default: label = installing ? "Installing system helper…" : setupNeeded ? "System helper required" : active ? "Starting…" : status?.owned == true ? "Restoring normal sleep…" : "Off"
        }
        let symbol = active && mode == "awake" ? "sun.max.fill" : active ? "pause.circle" : "moon.zzz"
        var state = PanelState()
        state.title = label
        state.reason = mode == "error" ? (status?.reason ?? "Unknown") :
            localReason ?? status?.reason ?? ""
        if let error = status?.auditError { state.reason += (state.reason.isEmpty ? "" : " · ") + error }
        if state.reason.isEmpty, untilAgents, !active, !setupNeeded, !agentStartAllowed {
            state.reason = agents.unknownCount > 0 ? "Agent status unavailable" : "Start a local agent task first."
        }
        state.symbol = symbol
        state.active = active
        state.setupNeeded = setupNeeded && !active
        state.setupPending = installing || uninstallPending
        state.primaryTitle = active ? "Stop" : setupNeeded ? (status == nil ? "Install system helper…" : "Update system helper…") : "Start"
        state.primaryEnabled = !uninstallPending && !installing && (active || setupNeeded || (canStart && agentStartAllowed))
        state.canChangeSettings = !uninstallPending && !installing
        state.canChangeMode = !uninstallPending && !installing && (untilAgents || (status?.protocolVersion ?? 0) >= 2)
        state.settings = settings
        state.untilAgents = untilAgents
        func counts(_ provider: String) -> ProviderCounts {
            let items = agents.observations.filter { $0.provider == provider }
            return ProviderCounts(working: items.filter { $0.state == .working }.count,
                                  waiting: items.filter { $0.state == .waiting }.count,
                                  unknown: items.filter { $0.state == .unknown }.count)
        }
        state.codex = counts("codex")
        state.claude = counts("Claude Code")
        state.unknownAgents = agents.unknownCount > 0
        var power: [String] = []
        if let onAC = status?.onAC { power.append(onAC ? "Power adapter" : "Battery") }
        if let battery = status?.battery { power.append("\(battery)%") }
        state.power = power.isEmpty ? "Unknown" : power.joined(separator: " · ")
        state.thermal = ["nominal": "Normal", "fair": "Warm", "serious": "Too warm", "critical": "Critical"][status?.thermal ?? ""] ?? "Unknown"
        if active, let seconds = status?.remainingSeconds {
            state.remaining = "\(max(1, (seconds + 59) / 60)) min"
        } else { state.remaining = settings.sessionMinutes == 0 ? "No time limit" : "\(settings.sessionMinutes) min" }
        let loginState = SMAppService.mainApp.status
        state.login = loginState == .enabled || loginState == .requiresApproval
        state.loginTitle = loginState == .requiresApproval ? "Launch at login: approval required…" : "Launch at login"
        state.claudeConnected = claudeConnected
        state.canChangeHooks = !active && !uninstallPending && !installing
        state.canUninstall = status != nil && !uninstallPending && !installing
        if let history, let summary = history.summaries.last(where: history.shouldPresentSummary) {
            state.latestSummaryTitle = "Last session: \(duration(summary.closedSeconds))"
        }
        panelController.rootView = WakePanelView(state: state, actions: panelActions())
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WakeGuard: \(label)")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = state.reason.isEmpty ? label : "\(label): \(state.reason)"
        plugins.publish(PluginEvent(type: "snapshot", timestamp: Date().timeIntervalSince1970,
            session: PluginSessionState(active: active, mode: status?.mode ?? "unavailable",
                reason: localReason ?? status?.reason ?? "", onAC: status?.onAC, battery: status?.battery,
                thermal: status?.thermal ?? "unknown", lidClosed: status?.lidClosed),
            agents: PluginAgentCounts(working: agents.observations.filter { $0.state == .working }.count,
                                     waiting: agents.waitingCount, unknown: agents.unknownCount), command: nil))
    }

    private func duration(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds, 1e9)))
        if value < 60 { return "\(value) sec" }
        if value < 3600 { return "\(value / 60) min \(value % 60) sec" }
        return "\(value / 3600) hr \((value % 3600) / 60) min"
    }

    private func summaryPresentation(_ summary: LidSummary) -> SummaryPresentation {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        var metrics = [SummaryMetric(label: summary.incomplete ? "Recorded period" : "Closed-lid duration", value: duration(summary.closedSeconds)),
                       SummaryMetric(label: "Kept awake", value: duration(summary.protectedAwakeSeconds)),
                       SummaryMetric(label: "WakeGuard inactive", value: duration(summary.unprotectedAwakeSeconds + summary.sleepingSeconds)),
                       SummaryMetric(label: "System sleep", value: duration(summary.sleepingSeconds))]
        if summary.unknownSeconds > 0 { metrics.append(SummaryMetric(label: "Unobserved time", value: duration(summary.unknownSeconds))) }
        var reasons: [String] = []
        if let reason = summary.lastStopReason, !reason.isEmpty { reasons.append(reason) }
        if summary.incomplete { reasons.append("Some time could not be observed; the recorded period may be incomplete.") }
        return SummaryPresentation(id: summary.id, title: "Session summary",
            subtitle: formatter.string(from: Date(timeIntervalSince1970: summary.closedAt)),
            metrics: metrics, reason: reasons.joined(separator: " "))
    }

    private func activityPresentation() -> ActivityPresentation {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM HH:mm:ss"
        let titles = ["helper_start": "System helper started", "state_changed": "Status changed",
                      "lid_closed": "Lid closed", "lid_opened": "Lid opened", "lid_unknown": "Lid state unavailable",
                      "sleep_observed": "System sleep recorded", "agent_sleep_requested": "Agents finished; sleep requested",
                      "recovery": "Normal sleep restored", "helper_recovered": "System helper recovered", "audit_reset": "Activity history reset",
                      "error": "Error", "stop": "Session stopped"]
        let rows = (history?.events ?? []).reversed().map { event in
            let title: String
            if event.kind == "state_changed" {
                title = event.verifiedAwake ? "Sleep prevention confirmed" :
                    ["off": "WakeGuard off", "awake": "Sleep prevention unconfirmed", "paused": "Paused",
                     "error": "Error", "stopped": "Session stopped"][event.mode] ?? "Status changed"
            } else { title = titles[event.kind] ?? "Status changed" }
            var detail = [event.reason == title ? "" : event.reason, event.durationSeconds.map(duration) ?? ""]
                .filter { !$0.isEmpty }
            if event.kind == "state_changed" {
                detail.append(event.onAC.map { $0 ? "Power adapter" : "Battery" } ?? "Power source unknown")
                if let battery = event.battery { detail.append("\(battery)%") }
                if event.thermal != "nominal" {
                    let thermal = ["fair": "Warm", "serious": "Too warm", "critical": "Critical"][event.thermal] ?? "Unknown"
                    detail.append("Thermal status: \(thermal)")
                }
            }
            return ActivityRow(id: event.id, time: formatter.string(from: Date(timeIntervalSince1970: event.at)),
                        title: title,
                        detail: detail.joined(separator: " · "))
        }
        return ActivityPresentation(rows: rows,
            summaries: (history?.summaries ?? []).reversed()
                .filter { history?.shouldPresentSummary($0) == true }.map(summaryPresentation))
    }

    private func refreshHistory() {
        guard (status?.protocolVersion ?? 0) >= WakePaths.helperProtocol else { return }
        let latest = status?.latestSummaryID
        if history == nil || latest != lastReadSummaryID || popover.isShown || activityWindow?.window?.isVisible == true {
            if let value = try? AuditClient().history() {
                history = value
                if value.includesSummary(latest) { lastReadSummaryID = latest }
                activityWindow?.update(activityPresentation())
            }
        }
        if !observedSummaryBaseline {
            observedSummaryBaseline = true
            if defaults.string(forKey: "lastSummaryID") == nil, let latest {
                defaults.set(latest, forKey: "lastSummaryID")
            }
        }
        guard status?.lidClosed == false, let latest,
              defaults.string(forKey: "lastSummaryID") != latest,
              let summary = history?.summaries.first(where: { $0.id == latest && $0.openedAt != nil }) else { return }
        defaults.set(latest, forKey: "lastSummaryID")
        guard history?.shouldPresentSummary(summary) == true else { return }
        popover.performClose(nil)
        summaryWindow?.close()
        summaryWindow = SummaryWindowController(state: summaryPresentation(summary), activity: { [weak self] in self?.showActivity() })
        NSApp.activate(ignoringOtherApps: true)
        summaryWindow?.present()
    }

    private func showActivity() {
        popover.performClose(nil)
        do {
            history = try AuditClient().history()
            if activityWindow == nil { activityWindow = ActivityWindowController(state: activityPresentation()) }
            else { activityWindow?.update(activityPresentation()) }
            activityWindow?.present()
        } catch { showError(error.localizedDescription) }
    }

    private func showPlugins() {
        popover.performClose(nil)
        if pluginsWindow == nil { pluginsWindow = PluginsWindowController(manager: plugins) }
        pluginsWindow?.present()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard filenames.count == 1 else { sender.reply(toOpenOrPrint: .failure); return }
        showPlugins()
        plugins.prepareInstall(file: URL(fileURLWithPath: filenames[0]))
        sender.reply(toOpenOrPrint: .success)
    }

    private func toggleSession() {
        guard !uninstallPending && !helperSetup.isInstalling else { return }
        if session != nil {
            do { try send(enabled: false); disarm("Stopped", stopHelper: false) }
            catch { disarm("Stop unconfirmed; the system helper stops when the connection expires") }
        } else {
            do {
                let snapshot = try client.status()
                guard (snapshot.protocolVersion ?? 0) >= WakePaths.helperProtocol else {
                    throw LeaseError.invalid("Update the system helper")
                }
                guard snapshot.mode != "error", !snapshot.owned else {
                    throw LeaseError.invalid("Wait for normal sleep to be restored before starting")
                }
                if untilAgents {
                    guard agentWaiter.arm(currentAgents(), now: ProcessInfo.processInfo.systemUptime) else {
                        throw LeaseError.invalid("No confirmed active agents. Start a local agent task first.")
                    }
                }
                generation = snapshot.generation
                session = UUID().uuidString
                sequence = 0
                startedAt = Date().timeIntervalSince1970
                localReason = nil
                try send(enabled: true)
                status = snapshot
            } catch { disarm(error.localizedDescription); showError(error.localizedDescription) }
        }
        updateMenu()
    }

    private func send(enabled: Bool, uninstall: Bool = false, sleepAfterAgents: Bool = false) throws {
        guard let generation, let session else { throw LeaseError.invalid("No active session") }
        guard sequence < UInt64.max else { throw LeaseError.invalid("Session counter exhausted; start again") }
        sequence += 1
        try client.send(WakeRequest(generation: generation, session: session, sequence: sequence,
                                    enabled: enabled, issuedAt: Date().timeIntervalSince1970,
                                    settings: settings, uninstall: uninstall, sleepAfterAgents: sleepAfterAgents))
    }

    private func disarm(_ reason: String, stopHelper: Bool = true) {
        if stopHelper, session != nil { try? send(enabled: false) }
        session = nil
        generation = nil
        agentWaiter.disarm()
        localReason = reason
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "settings") }
        if session != nil {
            do { try send(enabled: true) }
            catch { disarm(error.localizedDescription) }
        }
        updateMenu()
    }

    private func currentAgents() -> AgentSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastAgentRead > 0, now >= lastAgentRead, now - lastAgentRead < 12 else {
            return AgentSnapshot(observations: agentSnapshot.observations, unknownSources: agentSnapshot.unknownSources + 1)
        }
        return agentSnapshot
    }

    private func pollAgents() {
        guard !agentReadPending else { return }
        agentReadPending = true
        let readStartedAt = ProcessInfo.processInfo.systemUptime
        agentQueue.async {
            let codex = self.codexReader.snapshot()
            let claude = self.claudeReader.snapshot()
            let result = AgentSnapshot(observations: codex.observations + claude.observations,
                                       unknownSources: codex.unknownSources + claude.unknownSources)
            DispatchQueue.main.async {
                self.agentSnapshot = result
                self.lastAgentRead = readStartedAt
                self.agentReadPending = false
                if self.session != nil && self.untilAgents && !self.uninstallPending &&
                    self.agentWaiter.step(self.currentAgents(), now: ProcessInfo.processInfo.systemUptime) {
                    do {
                        try self.send(enabled: false, sleepAfterAgents: true)
                        self.disarm("Agents finished", stopHelper: false)
                    } catch { self.disarm("Stop unconfirmed; the system helper stops when the connection expires") }
                }
                self.updateMenu()
            }
        }
    }

    private func toggleAgentMode() {
        let next = !untilAgents
        if next && (status?.protocolVersion ?? 0) < 2 {
            showError("Update the system helper to use agent mode")
            return
        }
        if next && session != nil && !agentWaiter.arm(currentAgents(), now: ProcessInfo.processInfo.systemUptime) {
            showError("No confirmed active agents. Start a local agent task first.")
            return
        }
        untilAgents = next
        defaults.set(next, forKey: "untilAgents")
        if !next { agentWaiter.disarm() }
        updateMenu()
    }

    private func configureClaude(enabled: Bool) {
        guard session == nil && !uninstallPending && !helperSetup.isInstalling else { return }
        popover.performClose(nil)
        if enabled && Bundle.main.bundleURL.path != WakePaths.installedApp {
            showError("Move WakeGuard to Applications and open it there before connecting Claude Code")
            return
        }
        let alert = NSAlert()
        alert.messageText = enabled ? "Connect Claude Code?" : "Disconnect Claude Code?"
        alert.informativeText = enabled ?
            "Adds status hooks to ~/.claude/settings.json and resets stored agent status. Existing hooks are preserved. Restart Claude Code sessions after connecting." :
            "Removes WakeGuard hooks from ~/.claude/settings.json. Restart Claude Code sessions after disconnecting."
        alert.addButton(withTitle: enabled ? "Connect" : "Disconnect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ClaudeHooks.setEnabled(enabled)
            claudeConnected = enabled
            defaults.set(enabled, forKey: "claudeConnected")
            if enabled {
                try ClaudeEventReporter.reset()
                agentSnapshot = AgentSnapshot(unknownSources: 1)
                lastAgentRead = 0
                agentQueue.async { self.claudeReader = ClaudeActivityReader() }
            }
            localReason = "Connection updated. Restart Claude Code."
        } catch { showError(error.localizedDescription) }
        updateMenu()
    }

    private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { showError("Cannot launch at login: \(error.localizedDescription)") }
        updateMenu()
    }

    private func openInstaller() {
        guard session == nil && !uninstallPending && !helperSetup.isInstalling else { return }
        popover.performClose(nil)
        helperSetup.install { [weak self] result in
            guard let self else { return }
            switch result {
            case .installed:
                self.localReason = nil
                self.tick()
                if (self.status?.protocolVersion ?? 0) < WakePaths.helperProtocol {
                    self.showError("System helper unconfirmed; try again")
                }
            case .cancelled: self.localReason = "System helper installation cancelled"
            case .failed(let message): self.localReason = message; self.showError(message)
            }
            self.updateMenu()
        }
        updateMenu()
    }

    private func uninstall() {
        guard !uninstallPending && !helperSetup.isInstalling else { return }
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Remove system helper?"
        alert.informativeText = "Restores normal sleep and removes the system helper and its activity history. The app and settings remain."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let snapshot = try client.status()
            generation = snapshot.generation
            session = UUID().uuidString
            sequence = 0
            try send(enabled: false, uninstall: true)
            uninstallPending = true
            startedUninstallAt = Date().timeIntervalSince1970
            localReason = "Removing system helper…"
        } catch { disarm(error.localizedDescription); showError(error.localizedDescription) }
        updateMenu()
    }

    private func showAbout() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "WakeGuard"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        alert.informativeText = "Version \(version)\nApple Silicon · macOS 13 or later"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ text: String) {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "WakeGuard"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func quit() {
        if session != nil { try? send(enabled: false, uninstall: uninstallPending) }
        disarm("Stopped", stopHelper: false)
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if session != nil { try? send(enabled: false, uninstall: uninstallPending) }
        disarm("Stopped", stopHelper: false)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        plugins.shutdown()
        if session != nil { try? send(enabled: false, uninstall: uninstallPending) }
    }
}

@main struct WakeGuardApp {
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--run-plugin"] {
            PluginRuntime.runFromStandardInput()
            return
        }
        if CommandLine.arguments.dropFirst() == ["--claude-event"] {
            ClaudeEventReporter.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
