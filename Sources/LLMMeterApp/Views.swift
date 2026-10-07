import AppKit
import LLMMeterCore
import ServiceManagement
import SwiftUI

struct UsagePanel: View {
  @ObservedObject var store: AppStore
  var maximumContentHeight: () -> CGFloat
  var openSettings: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: MenuBarController.icon(size: 22))
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("LLM Meter").font(.system(size: 14, weight: .semibold))
          Text("Usage overview").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        Text(store.settings.showRemaining ? "Remaining" : "Used")
          .font(.system(size: 10, weight: .medium))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.primary.opacity(0.06), in: Capsule())
          .help(
            "Green: under 50% used. Orange: 50% to below 80% used. Red: 80% or more used. Colors keep the same meaning when displaying remaining allowance. Retained or unknown readings are gray."
          )
      }.padding(16)
      Divider()
      if let message = store.message {
        Text(message).font(.caption).foregroundStyle(.red).padding(12)
      }
      HStack(spacing: 0) {
        Text("SERVICE").frame(maxWidth: .infinity, alignment: .leading)
        Text("5 HOURS").frame(width: 105, alignment: .trailing)
        Text("WEEKLY").frame(width: 105, alignment: .trailing)
      }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
      if store.visibleServices.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "list.bullet").font(.title2).foregroundStyle(.secondary)
          Text("No services selected").font(.headline)
          Text("Choose which LLMs to display in Settings.").font(.caption).foregroundStyle(
            .secondary)
        }.padding(24)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(store.visibleServices.enumerated()), id: \.element.id) { index, service in
              if index > 0 { Divider().padding(.vertical, 6) }
              if service.provider == .antigravity,
                !store.antigravityPools.isEmpty || !store.antigravityModels.isEmpty
              {
                antigravityRows
              } else if service.provider == .copilot, !store.copilotMetrics.isEmpty {
                copilotRows
              } else {
                serviceRow(service.provider)
              }
            }
          }.padding(.horizontal, 16).padding(.bottom, 8)
        }.frame(height: contentHeight)
      }
      Divider()
      Text(store.panelUpdateLabel).font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 10)
        .help(store.panelUpdateDetails)
      HStack(spacing: 8) {
        action(store.refreshing ? "Refreshing…" : "Refresh", symbol: "arrow.clockwise") {
          store.refresh()
        }.disabled(store.refreshing)
        action("Settings", symbol: "gearshape", action: openSettings)
        Button("Quit") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 8)
      }.padding(12)
    }.frame(width: 380)
  }

  private var contentHeight: CGFloat {
    let rows = store.visibleServices.reduce(0) { total, service in
      if service.provider == .copilot, !store.copilotMetrics.isEmpty {
        return total + 32 + store.copilotMetrics.count * 60
      }
      let count =
        store.antigravityPools.isEmpty
        ? store.antigravityModels.count : store.antigravityPools.count
      return total + (service.provider == .antigravity && count > 0 ? 32 + count * 60 : 64)
    }
    return min(
      maximumContentHeight(),
      CGFloat(rows + max(0, store.visibleServices.count - 1) * 12 + 8))
  }

  private func serviceRow(_ id: ProviderID) -> some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 5) {
        Text(id.name).font(.system(size: 13, weight: .medium))
        if let status = store.serviceStatusLabel(id) {
          Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      window(id, period: .fiveHours)
      window(id, period: .weekly)
    }.padding(.vertical, 10).contentShape(Rectangle()).help(store.tooltip(id))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(id.name), 5 hours \(store.label(id, period: .fiveHours)), weekly \(store.label(id, period: .weekly)). \(store.tooltip(id))"
      )
  }

  private var antigravityRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Antigravity").font(.system(size: 13, weight: .medium))
        Spacer()
        if let status = store.serviceStatusLabel(.antigravity) {
          Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.padding(.top, 10).padding(.bottom, 6)
      if !store.antigravityPools.isEmpty {
        ForEach(store.antigravityPools, id: \.self) { scope in
          HStack(spacing: 0) {
            Text(String(scope.dropFirst(5))).font(.system(size: 11))
              .foregroundStyle(.secondary).lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
            window(.antigravity, period: .fiveHours, scope: scope)
            window(.antigravity, period: .weekly, scope: scope)
          }.padding(.vertical, 10)
        }
      } else {
        ForEach(store.antigravityModels) { metric in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(metric.name).font(.system(size: 11, weight: .medium))
              Text("Model quota · window unknown").font(.system(size: 10)).foregroundStyle(
                .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
              value(store.modelLabel(metric), used: metric.usedPercent)
              Text(UsageDisplay.resetCountdown(metric.resetAt, now: store.now)).font(
                .system(size: 10)
              )
              .foregroundStyle(.secondary)
            }
          }.padding(.vertical, 10)
        }
      }
    }.help(store.tooltip(.antigravity))
  }

  private var copilotRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("GitHub Copilot").font(.system(size: 13, weight: .medium))
        Spacer()
        Text("Monthly").font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.top, 10).padding(.bottom, 6)
      ForEach(store.copilotMetrics) { metric in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(metric.name).font(.system(size: 11, weight: .medium))
            if !metric.unlimited {
              Text(store.countLabel(metric)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 5) {
            value(store.metricLabel(.copilot, metric: metric), used: metric.usedPercent)
            if !metric.unlimited {
              Text(UsageDisplay.resetCountdown(metric.resetAt, now: store.now)).font(
                .system(size: 10)
              )
              .foregroundStyle(.secondary)
            }
          }
        }.padding(.vertical, 10)
      }
    }.help(store.tooltip(.copilot))
  }

  private func value(_ label: String, used: Double?) -> some View {
    Text(label).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
      .foregroundStyle(usageColor(label, used: used))
  }

  private func usageColor(_ label: String, used: Double?) -> Color {
    guard label != "—", !label.hasSuffix("·"), let used, used.isFinite, used >= 0 else {
      return .secondary
    }
    if used >= 80 { return Color(nsColor: .systemRed) }
    if used >= 50 { return Color(nsColor: .systemOrange) }
    return Color(nsColor: .systemGreen)
  }

  private func window(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> some View {
    VStack(alignment: .trailing, spacing: 5) {
      value(
        store.label(id, period: period, scope: scope),
        used: store.metric(id, period: period, scope: scope)?.usedPercent)
      Text(store.resetLabel(id, period: period, scope: scope)).font(.system(size: 10))
        .monospacedDigit().foregroundStyle(.secondary)
    }.frame(width: 105, alignment: .trailing)
  }

  private func action(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(text, systemImage: symbol).font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
    }.buttonStyle(PanelActionStyle())
  }
}

private struct PanelActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.background(
      Color.primary.opacity(configuration.isPressed ? 0.12 : 0.05),
      in: RoundedRectangle(cornerRadius: 7))
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
          "Service usage shows the service icon and percentage. Select a metric after its first successful refresh."
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
    case .copilot: "Auto-detect Copilot editor / CLI sign-in"
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
    case .copilot:
      "Reads github.com Copilot editor sign-in or Copilot CLI config and an already accessible Keychain token. Optional single-account OAuth JSON. Monthly quotas retain AI-credit/request units; no login, token renewal, or inference requests."
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
