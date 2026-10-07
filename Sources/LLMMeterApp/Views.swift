import AppKit
import LLMMeterCore
import ServiceManagement
import SwiftUI

struct UsagePanel: View {
  @ObservedObject var store: AppStore
  var openSettings: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(nsImage: MenuBarController.icon())
        Text("LLMeter").fontWeight(.semibold)
        Spacer()
        Text(store.settings.showRemaining ? "Remaining" : "Used").font(.caption).foregroundStyle(
          .secondary)
      }.padding(12)
      Divider()
      if let message = store.message {
        Text(message).font(.caption).foregroundStyle(.red).padding(10)
      }
      HStack {
        Text("LLM").frame(maxWidth: .infinity, alignment: .leading)
        Text("5h").frame(width: 105, alignment: .trailing)
        Text("Weekly").frame(width: 105, alignment: .trailing)
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
      if store.visibleServices.isEmpty {
        Text("No LLMs selected for display").foregroundStyle(.secondary).padding(12)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(store.visibleServices) { service in
              if service.provider == .antigravity,
                !store.antigravityPools.isEmpty || !store.antigravityModels.isEmpty
              {
                antigravityRows
              } else {
                HStack(spacing: 0) {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(service.provider.name)
                    Text(store.updateLabel(service.provider)).font(.caption2)
                      .foregroundStyle(.secondary)
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  window(service.provider, period: .fiveHours)
                  window(service.provider, period: .weekly)
                }
                .monospacedDigit().padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle()).help(store.tooltip(service.provider))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                  "\(service.provider.name), 5 hours \(store.label(service.provider, period: .fiveHours)), weekly \(store.label(service.provider, period: .weekly)). \(store.tooltip(service.provider))"
                )
              }
            }
          }
        }.frame(height: CGFloat(min(store.panelRows, 8) * 52))
      }
      Divider().padding(.top, 6)
      VStack(spacing: 0) {
        action(store.refreshing ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise") {
          store.refresh()
        }
        .disabled(store.refreshing)
        action("Settings…", symbol: "gearshape", action: openSettings)
        action("Quit", symbol: "power") { NSApplication.shared.terminate(nil) }
      }.padding(.vertical, 4)
    }.frame(width: 380)
  }
  private var antigravityRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Antigravity").fontWeight(.medium)
        Spacer()
        Text(store.updateLabel(.antigravity)).font(.caption2).foregroundStyle(.secondary)
      }.padding(.vertical, 8)
      if !store.antigravityPools.isEmpty {
        ForEach(store.antigravityPools, id: \.self) { scope in
          HStack(spacing: 0) {
            Text(String(scope.dropFirst(5))).font(.caption)
              .frame(maxWidth: .infinity, alignment: .leading)
            window(.antigravity, period: .fiveHours, scope: scope)
            window(.antigravity, period: .weekly, scope: scope)
          }.padding(.vertical, 8)
        }
      } else {
        ForEach(store.antigravityModels) { metric in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(metric.name).font(.caption)
              Text("Model quota · window unknown").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
              Text(store.modelLabel(metric))
              Text(UsageDisplay.resetCountdown(metric.resetAt, now: store.now)).font(.caption2)
                .foregroundStyle(.secondary)
            }
          }.padding(.vertical, 8)
        }
      }
    }.monospacedDigit().padding(.horizontal, 12).help(store.tooltip(.antigravity))
  }
  private func window(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> some View {
    VStack(alignment: .trailing, spacing: 3) {
      Text(store.label(id, period: period, scope: scope))
      Text(store.resetLabel(id, period: period, scope: scope)).font(.caption2).foregroundStyle(
        .secondary)
    }.frame(width: 105, alignment: .trailing)
  }
  private func action(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(text, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

struct SettingsView: View {
  @ObservedObject var store: AppStore
  @State private var loginStatus = SMAppService.mainApp.status
  @State private var loginError: String?
  var body: some View {
    TabView {
      Form {
        Picker("Display", selection: binding(\.showUsage)) {
          Text("Default icon").tag(false)
          Text("Service usage").tag(true)
        }
        Picker(
          "Service",
          selection: Binding(
            get: { store.settings.selectedProvider }, set: { store.selectProvider($0) })
        ) {
          ForEach(ProviderID.allCases) { Text($0.name).tag($0) }
        }.disabled(!store.settings.showUsage)
        Picker(
          "Metric",
          selection: Binding(
            get: { store.settings.selectedMetricID }, set: { store.selectMetric($0) })
        ) {
          let metrics = store.states[store.settings.selectedProvider]?.snapshot?.metrics ?? []
          if !metrics.contains(where: { $0.id == store.settings.selectedMetricID }) {
            Text("Awaiting selected metric").tag(store.settings.selectedMetricID)
          }
          ForEach(metrics) { metric in Text(metric.name).tag(metric.id) }
        }.disabled(!store.settings.showUsage)
        Picker("Values", selection: binding(\.showRemaining)) {
          Text("Used").tag(false)
          Text("Remaining").tag(true)
        }
        Text(
          "Service usage shows a short service label and percentage without an icon. Select a metric after its first successful refresh."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let snapshot = store.states[store.settings.selectedProvider]?.snapshot,
          store.settings.selectedAccountID != nil,
          snapshot.accountID != store.settings.selectedAccountID
        {
          Text("The signed-in account changed. Choose a metric to bind the new account.")
            .foregroundStyle(.orange)
        }
      }.formStyle(.grouped).tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(Array(store.settings.services.enumerated()), id: \.element.id) { index, service in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(service.provider.name).font(.headline)
                Spacer()
                Button {
                  store.move(service.provider, by: -1)
                } label: {
                  Image(systemName: "arrow.up")
                }
                .disabled(index == 0).help("Move up")
                Button {
                  store.move(service.provider, by: 1)
                } label: {
                  Image(systemName: "arrow.down")
                }
                .disabled(index == store.settings.services.count - 1).help("Move down")
              }
              HStack {
                Toggle("Show in list", isOn: serviceBinding(service.provider, \.visible))
                Toggle("Enable monitoring", isOn: serviceBinding(service.provider, \.enabled))
              }
              HStack {
                TextField(
                  sourcePlaceholder(service.provider),
                  text: serviceBinding(service.provider, \.sourcePath)
                )
                .textFieldStyle(.roundedBorder)
                Button("Choose…") { choose(service.provider) }
              }
              Text(sourceDescription(service.provider)).font(.caption).foregroundStyle(.secondary)
              HStack {
                Button("Validate / Refresh") { store.refresh(service.provider) }.disabled(
                  !service.enabled)
                Button("Use default source") {
                  store.editService(service.provider) { $0.sourcePath = "" }
                }
              }
              Text(store.tooltip(service.provider)).font(.caption).textSelection(.enabled)
              Divider()
            }
          }
        }.padding(16)
      }.tabItem { Label("Services", systemImage: "list.bullet") }
      Form {
        Picker("Refresh interval", selection: binding(\.refreshMinutes)) {
          ForEach([1, 3, 5, 10], id: \.self) { Text("\($0) minutes").tag($0) }
        }
        Text(
          "Provider minimums and rate-limit cooldowns take precedence. Claude Code refreshes at most every 5 minutes automatically."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          "Launch at login", isOn: Binding(get: { loginStatus == .enabled }, set: { setLogin($0) }))
        if loginStatus == .requiresApproval {
          Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        Text("Local usage monitoring only. Credentials remain in their original sources.").font(
          .caption
        ).foregroundStyle(.secondary)
      }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
    }
    .padding(12).frame(width: 570, height: 480)
    .disabled(!store.canEditSettings)
    .onAppear { loginStatus = SMAppService.mainApp.status }
    .overlay(alignment: .bottom) {
      if let message = store.message {
        Text(message).font(.caption).foregroundStyle(.red).padding(8).background(.regularMaterial)
      }
    }
  }
  private func binding<T>(_ key: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
      get: { store.settings[keyPath: key] },
      set: { value in store.change { $0[keyPath: key] = value } })
  }
  private func serviceBinding<T>(_ id: ProviderID, _ key: WritableKeyPath<ServiceConfiguration, T>)
    -> Binding<T>
  {
    Binding(
      get: { store.settings.services.first { $0.provider == id }![keyPath: key] },
      set: { value in store.editService(id) { $0[keyPath: key] = value } })
  }
  private func sourcePlaceholder(_ id: ProviderID) -> String {
    switch id {
    case .codex: "Default: ~/.codex/auth.json"
    case .claude: "Auto-detect claude executable"
    case .antigravity: "Auto-detect running Antigravity (optional OAuth JSON)"
    }
  }
  private func sourceDescription(_ id: ProviderID) -> String {
    switch id {
    case .codex:
      "Uses a subscription auth.json file (including CODEX_HOME). Tokens are never renewed by LLM Meter."
    case .claude:
      "Requires Claude Code 2.1.285+. Runs its read-only /usage command; no model requests or tools."
    case .antigravity:
      "Leave blank to read the running Antigravity app's local quota status. Keep it open and signed in. Optional fallback: an OAuth JSON with a current access_token. Quota groups and model metrics can be selected in Menu Bar."
    }
  }
  private func choose(_ id: ProviderID) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message =
      id == .claude ? "Choose the Claude Code executable" : "Choose an existing sign-in JSON file"
    if panel.runModal() == .OK, let url = panel.url {
      store.editService(id) { $0.sourcePath = url.path }
    }
  }
  private func setLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginError = nil
    } catch {
      loginError =
        "Could not change launch at login. Check System Settings → General → Login Items."
    }
    loginStatus = SMAppService.mainApp.status
  }
}
