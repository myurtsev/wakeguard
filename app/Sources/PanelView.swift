import AppKit
import SwiftUI

struct ProviderCounts {
    var working = 0
    var waiting = 0
    var unknown = 0

    var description: String {
        var parts = ["\(max(0, working)) working"]
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: " · ")
    }
}

struct PanelState {
    var title = "Off"
    var reason = ""
    var symbol = "moon.zzz"
    var primaryTitle = "Start"
    var primaryEnabled = false
    var active = false
    var setupNeeded = false
    var setupPending = false
    var canChangeSettings = true
    var canChangeMode = true
    var settings = WakeSettings()
    var untilAgents = false
    var codex = ProviderCounts()
    var claude = ProviderCounts()
    var unknownAgents = false
    var power = "Power unknown"
    var thermal = "Unknown"
    var remaining = "60 minutes"
    var login = false
    var loginTitle = "Open at login"
    var claudeConnected = false
    var canChangeHooks = true
    var canUninstall = false
    var latestSummaryTitle = ""
}

struct PanelActions {
    let main: () -> Void
    let mode: (Bool) -> Void
    let ac: (Bool) -> Void
    let battery: (Bool) -> Void
    let login: (Bool) -> Void
    let floor: (Int) -> Void
    let duration: (Int) -> Void
    let claude: (Bool) -> Void
    let setup: () -> Void
    let uninstall: () -> Void
    let about: () -> Void
    let quit: () -> Void
    let activity: () -> Void
    let plugins: () -> Void
    let computerUse: () -> Void
}

private struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content.frame(maxWidth: .infinity)
            }
        }
    }
}

struct WakePanelView: View {
    let state: PanelState
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("WakeGuard").font(.headline)
                Spacer()
                Menu {
                    Button("Plugins…", action: actions.plugins)
                    Divider()
                    Button(state.claudeConnected ? "Disconnect Claude Code…" : "Connect Claude Code…") {
                        actions.claude(!state.claudeConnected)
                    }.disabled(!state.canChangeHooks)
                    if state.setupNeeded {
                        Button("Set up system helper…", action: actions.setup)
                            .disabled(state.setupPending)
                    }
                    Button("Remove system helper…", action: actions.uninstall)
                        .disabled(!state.canUninstall)
                    Divider()
                    Button("About WakeGuard", action: actions.about)
                    Button("Quit WakeGuard", action: actions.quit).keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More options")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if state.setupPending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.symbol).accessibilityHidden(true)
                    }
                    Text(state.title).font(.title3.weight(.semibold))
                }
                if !state.reason.isEmpty {
                    Text(state.reason).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: state.setupNeeded ? actions.setup : actions.main) {
                Text(state.primaryTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!state.primaryEnabled)
            .keyboardShortcut(.defaultAction)

            Picker("Keep awake", selection: Binding(get: { state.untilAgents }, set: actions.mode)) {
                Text("Manual").tag(false)
                Text("Until agents finish").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Keep awake")
            .disabled(!state.canChangeMode)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Agents").font(.headline)
                    Spacer()
                    if state.unknownAgents {
                        Label("Unknown status", systemImage: "questionmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                providerRow("Codex", counts: state.codex)
                providerRow("Claude Code", counts: state.claude)
            }

            Divider()
            VStack(spacing: 7) {
                detail("Power", value: state.power, symbol: "bolt")
                detail("Thermal status", value: state.thermal, symbol: "thermometer.medium")
                detail(state.active ? "Remaining" : "Time limit", value: state.remaining, symbol: "clock")
            }

            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("AC power", isOn: Binding(get: { state.settings.onAC }, set: actions.ac))
                        Toggle("Battery", isOn: Binding(get: { state.settings.onBattery }, set: actions.battery))
                    }
                    Picker("Battery limit", selection: Binding(get: { state.settings.batteryFloor }, set: actions.floor)) {
                        ForEach([20, 30, 40], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    Picker("Time limit", selection: Binding(get: { state.settings.sessionMinutes }, set: actions.duration)) {
                        ForEach([30, 60, 120, 0], id: \.self) { value in
                            Text(value == 0 ? "No time limit" : "\(value) minutes").tag(value)
                        }
                    }
                    Toggle(state.loginTitle, isOn: Binding(get: { state.login }, set: actions.login))
                    Button("Codex setup…", action: actions.computerUse).buttonStyle(.borderless)
                }
                .padding(.top, 10)
                .toggleStyle(.checkbox)
                .disabled(!state.canChangeSettings)
            }
            .disclosureGroupStyle(SettingsDisclosureStyle())

            Divider()
            HStack(alignment: .top) {
                Button("Activity…", action: actions.activity).buttonStyle(.borderless)
                Spacer()
                if !state.latestSummaryTitle.isEmpty {
                    Text(state.latestSummaryTitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerRow(_ provider: String, counts: ProviderCounts) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(provider)
            Spacer(minLength: 8)
            Text(counts.description).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.font(.callout)
    }

    private func detail(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }.font(.callout)
    }
}

struct ComputerUseSetupView: View {
    let status: String
    let awake: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Codex setup").font(.title2.weight(.semibold))
            Text("For desktop app control with the lid closed.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            step("1", title: "Set up Computer Use",
                 detail: "In Codex, install the Computer Use plugin. Allow macOS Screen Recording and Accessibility when prompted.")
            step("2", title: "Enable Locked use",
                 detail: "In Codex, open Settings → Computer use.")
            step("3", title: "Allow the apps you need",
                 detail: "Choose Always allow when Codex requests access to an app you want it to use in future tasks.")
            VStack(alignment: .leading, spacing: 6) {
                step("4", title: "Start WakeGuard",
                     detail: "Check your power and time limits, then start a session.")
                Label(status, systemImage: awake ? "checkmark.circle.fill" : "circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            step("5", title: "Lock before closing the lid",
                 detail: "Press Control–Command–Q, then close the lid.")
            Divider()
            Text("Browser screenshots can work even when desktop app control is unavailable. WakeGuard cannot verify Codex permissions.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Computer use guide", destination: URL(string: "https://learn.chatgpt.com/docs/computer-use")!)
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

final class ComputerUseSetupWindowController: NSWindowController {
    private let content: NSHostingController<ComputerUseSetupView>

    init() {
        content = NSHostingController(rootView: ComputerUseSetupView(status: "Off", awake: false))
        content.sizingOptions.insert(.preferredContentSize)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "WakeGuard — Codex setup"
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setContentSize(content.view.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(status: String, awake: Bool) {
        content.rootView = ComputerUseSetupView(status: status, awake: awake)
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ActivityRow: Identifiable {
    var id: String
    var time: String
    var title: String
    var detail: String = ""
}

struct SummaryMetric: Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

struct SummaryPresentation: Identifiable {
    var id: String
    var title: String = "Session summary"
    var subtitle: String = ""
    var metrics: [SummaryMetric] = []
    var reason: String = ""
}

struct ActivityPresentation {
    var rows: [ActivityRow] = []
    var summaries: [SummaryPresentation] = []
    var retentionDays = 7
}

struct ActivityView: View {
    let state: ActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity").font(.title2.weight(.semibold))
                Spacer()
                Text("Last \(state.retentionDays) days").foregroundStyle(.secondary)
            }
            if state.rows.isEmpty && state.summaries.isEmpty {
                Text("No activity yet").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(state.summaries) { summary in
                            SummaryContent(state: summary)
                            Divider()
                        }
                        ForEach(state.rows) { row in
                            HStack(alignment: .top, spacing: 16) {
                                Text(row.time).font(.caption).foregroundStyle(.secondary)
                                    .frame(width: 105, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title)
                                    if !row.detail.isEmpty {
                                        Text(row.detail).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 360)
    }
}

final class ActivityWindowController: NSWindowController {
    private let content: NSHostingController<ActivityView>

    init(state: ActivityPresentation) {
        content = NSHostingController(rootView: ActivityView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "WakeGuard — Activity"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 360)
        window.contentViewController = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: ActivityPresentation) { content.rootView = ActivityView(state: state) }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SummaryContent: View {
    let state: SummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title).font(.headline)
            if !state.subtitle.isEmpty {
                Text(state.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(state.metrics) { metric in
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(metric.value).multilineTextAlignment(.trailing)
                }
            }
            if !state.reason.isEmpty {
                Text(state.reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SessionSummaryView: View {
    let state: SummaryPresentation
    let close: () -> Void
    let activity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SummaryContent(state: state)
            HStack {
                Button("Activity…", action: activity)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SummaryWindowController: NSWindowController {
    init(state: SummaryPresentation, activity: @escaping () -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "WakeGuard"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: SessionSummaryView(state: state,
            close: { [weak self] in self?.close() },
            activity: { [weak self] in self?.close(); activity() }))
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
