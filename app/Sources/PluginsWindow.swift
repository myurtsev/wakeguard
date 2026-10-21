import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Select the macOS 13 property wrapper instead of the newer State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct PluginsView: View {
    @ObservedObject var manager: PluginManager
    @ViewState private var installedSelected = false
    @ViewState private var search = ""
    @ViewState private var showURL = false
    @ViewState private var configuring: InstalledPlugin?
    @ViewState private var removing: InstalledPlugin?

    private var available: [PluginCatalogEntry] {
        manager.available.filter { matches([$0.name, $0.author, $0.description, $0.id]) }
    }

    private var installed: [InstalledPlugin] {
        manager.installed.filter { matches([$0.package.name, $0.package.author, $0.package.description, $0.id]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plugins").font(.title2.weight(.semibold))
                Spacer()
                if manager.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh", action: manager.refreshCatalog).disabled(manager.isBusy)
            }
            HStack(spacing: 12) {
                Picker("Show plugins", selection: $installedSelected) {
                    Text("Available").tag(false)
                    Text("Installed").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                TextField("Search plugins", text: $search).textFieldStyle(.roundedBorder)
            }
            if let error = manager.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { manager.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss error")
                }
            }
            if !installedSelected, let error = manager.catalogError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            if installedSelected ? installed.isEmpty : available.isEmpty {
                Text(search.isEmpty ? (installedSelected ? "No plugins installed" : "No plugins available") : "No matching plugins")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if installedSelected {
                            ForEach(installed) { plugin in
                                installedRow(plugin)
                                Divider()
                            }
                        } else {
                            ForEach(available) { entry in
                                availableRow(entry)
                                Divider()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .id(installedSelected)
                }
            }
            Divider()
            HStack {
                Button("Install from File…", action: installFile)
                Button("Install from URL…") { showURL = true }
                Spacer()
                Text("\(manager.installed.count) installed").font(.caption).foregroundStyle(.secondary)
            }.disabled(manager.isBusy)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .sheet(item: $manager.review) { review in
            PluginReviewView(manager: manager, review: review)
        }
        .sheet(isPresented: $showURL) {
            PluginURLView { value in
                showURL = false
                manager.prepareInstall(url: value)
            } cancel: { showURL = false }
        }
        .sheet(item: $configuring) { plugin in
            PluginSettingsView(manager: manager, plugin: plugin) { configuring = nil }
        }
        .alert("Remove plugin?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let plugin = removing { manager.remove(id: plugin.id) }
                removing = nil
            }
        } message: {
            Text("\(removing?.package.name ?? "This plugin") and its saved settings will be removed.")
        }
    }

    private func matches(_ values: [String]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func availableRow(_ entry: PluginCatalogEntry) -> some View {
        let current = manager.installed.first { $0.id == entry.id }
        let update = current.map { $0.package.version.compare(entry.version, options: .numeric) == .orderedAscending } ?? false
        return HStack(alignment: .top, spacing: 16) {
            pluginDetails(name: entry.name, author: entry.author, version: entry.version, description: entry.description)
            Spacer(minLength: 0)
            if let current, !update {
                Text("Installed \(current.package.version)").font(.callout).foregroundStyle(.secondary)
            } else {
                Button(update ? "Update…" : "Install…") { manager.prepareInstall(entry: entry) }
                    .disabled(manager.isBusy)
            }
        }
    }

    private func installedRow(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                pluginDetails(name: plugin.package.name, author: plugin.package.author,
                              version: plugin.package.version, description: plugin.package.description)
                Spacer(minLength: 0)
                Toggle("Enable \(plugin.package.name)", isOn: Binding(get: { plugin.enabled }, set: { manager.setEnabled(id: plugin.id, enabled: $0) }))
                    .toggleStyle(.switch).labelsHidden().disabled(manager.isBusy && !plugin.enabled)
                Menu {
                    if !plugin.package.settings.isEmpty {
                        Button("Configure…") { manager.error = nil; configuring = plugin }
                    }
                    ForEach(plugin.package.commands) { command in
                        Button(command.title) { manager.runCommand(id: plugin.id, command: command.id) }
                            .disabled(!plugin.enabled)
                    }
                    if !plugin.package.settings.isEmpty || !plugin.package.commands.isEmpty { Divider() }
                    Button("Remove…", role: .destructive) { removing = plugin }
                } label: { Label("Options for \(plugin.package.name)", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Options for \(plugin.package.name)").disabled(manager.isBusy)
            }
            if let error = plugin.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Text("Enable this plugin to retry.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(plugin.status.isEmpty ? (plugin.enabled ? "Enabled" : "Disabled") : plugin.status)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func pluginDetails(name: String, author: String, version: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            Text("\(author) · \(version)").font(.caption).foregroundStyle(.secondary)
            Text(description).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func installFile() {
        let panel = NSOpenPanel()
        panel.title = "Install Plugin"
        panel.prompt = "Review Plugin"
        panel.allowedContentTypes = [UTType(importedAs: "nl.local.WakeGuard.plugin"), .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { manager.prepareInstall(file: url) }
        }
    }
}

private struct PluginReviewView: View {
    @ObservedObject var manager: PluginManager
    let review: PluginInstallReview

    private var current: InstalledPlugin? { manager.installed.first { $0.id == review.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(current == nil ? "Install plugin?" : "Update plugin?").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(review.package.name).font(.headline)
                        Text("\(review.package.author) · \(review.package.version)").foregroundStyle(.secondary)
                        Text(review.package.description).font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source").font(.headline)
                        Text(review.source).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Permissions").font(.headline)
                        ForEach(review.package.permissions.descriptions, id: \.self) { permission in
                            Label(permission, systemImage: "checkmark").font(.callout)
                        }
                    }
                    Text("Only install plugins from authors you trust. This plugin will be disabled until you enable it.")
                        .font(.callout).foregroundStyle(.secondary)
                    if current != nil {
                        Text("Updating replaces the installed version and stops the plugin.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 360)
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel", action: manager.cancelInstall).keyboardShortcut(.cancelAction)
                    .disabled(manager.isBusy)
                Spacer()
                if manager.isBusy { ProgressView().controlSize(.small) }
                Button(current == nil ? "Install" : "Update", action: manager.confirmInstall)
                    .keyboardShortcut(.defaultAction).disabled(manager.isBusy)
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(manager.isBusy)
    }
}

private struct PluginURLView: View {
    let install: (String) -> Void
    let cancel: () -> Void
    @ViewState private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install from URL").font(.title2.weight(.semibold))
            TextField("HTTPS plugin package URL", text: $url).textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Plugin", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440)
    }

    private func submit() {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { install(value) }
    }
}

private struct PluginSettingsView: View {
    @ObservedObject var manager: PluginManager
    let plugin: InstalledPlugin
    let close: () -> Void
    @ViewState private var values: [String: String] = [:]
    @ViewState private var loading = true

    private var missingRequired: Bool {
        plugin.package.settings.contains { $0.required && (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(plugin.package.name).font(.title2.weight(.semibold))
                Spacer()
                if loading || manager.isBusy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plugin.package.settings) { setting in
                        if setting.type == "toggle" {
                            Toggle(setting.label, isOn: Binding(get: { values[setting.key] == "true" }, set: { values[setting.key] = $0 ? "true" : "false" }))
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(setting.label).font(.callout)
                                    if setting.required { Text("Required").font(.caption).foregroundStyle(.secondary) }
                                }
                                if setting.type == "secret" {
                                    SecureField(setting.label, text: value(setting.key)).privacySensitive()
                                        .labelsHidden().textFieldStyle(.roundedBorder)
                                } else {
                                    TextField(setting.label, text: value(setting.key))
                                        .labelsHidden().textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 350).disabled(loading || manager.isBusy)
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    manager.error = nil
                    manager.saveSettings(id: plugin.id, values: values) { success in
                        if success { close() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(loading || manager.isBusy || missingRequired)
            }
        }.padding(24).frame(width: 440)
        .onAppear {
            manager.settingsValues(id: plugin.id) { result in
                values = result
                loading = false
            }
        }
    }

    private func value(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
}

final class PluginsWindowController: NSWindowController {
    init(manager: PluginManager) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "WakeGuard — Plugins"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 380)
        window.contentViewController = NSHostingController(rootView: PluginsView(manager: manager))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
