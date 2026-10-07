import AppKit
import LLMMeterCore
import ServiceManagement
import SwiftUI

struct UsagePanel: View {
  @ObservedObject var store: AppStore
  var maximumContentHeight: () -> CGFloat
  var openSettings: () -> Void
  @State private var detailProvider: ProviderID?

  var body: some View {
    if let detailProvider {
      UsageDetailsView(
        store: store, provider: detailProvider,
        maximumContentHeight: maximumContentHeight
      ) { self.detailProvider = nil }
    } else {
      overview
    }
  }

  private var overview: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: MenuBarController.icon(size: 22))
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text("LLM Meter").font(.system(size: 14, weight: .semibold))
          Text(L10n.text("Usage overview")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer()
        Text(store.settings.showRemaining ? L10n.text("Remaining") : L10n.text("Used"))
          .font(.system(size: 10, weight: .medium))
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.primary.opacity(0.06), in: Capsule())
          .help(
            L10n.text(
              "Green: under 50% used. Orange: 50% to below 80% used. Red: 80% or more used. Colors keep the same meaning when displaying remaining allowance. Retained or unknown readings are gray."
            )
          )
      }.padding(16)
      Divider()
      if let message = store.message {
        Text(message).font(.caption).foregroundStyle(.red).padding(12)
      }
      HStack(spacing: 0) {
        Text(L10n.text("SERVICE")).frame(maxWidth: .infinity, alignment: .leading)
        Text(L10n.text("5 HOURS")).frame(width: 105, alignment: .trailing)
        Text(L10n.text("WEEKLY")).frame(width: 105, alignment: .trailing)
      }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
      if store.visibleServices.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "list.bullet").font(.title2).foregroundStyle(.secondary)
          Text(L10n.text("No services selected")).font(.headline)
          Text(L10n.text("Choose which LLMs to display in Settings.")).font(.caption)
            .foregroundStyle(
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
      Text(L10n.text("Click a service name or usage value for details."))
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 4)
      HStack(spacing: 8) {
        action(
          store.refreshing ? L10n.text("Refreshing…") : L10n.text("Refresh"),
          symbol: "arrow.clockwise"
        ) {
          store.refresh()
        }.disabled(store.refreshing)
        action(L10n.text("Settings"), symbol: "gearshape", action: openSettings)
        Button(L10n.text("Quit")) { NSApplication.shared.terminate(nil) }
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
        providerHeading(id)
        if let status = store.serviceStatusLabel(id) {
          Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      window(id, period: .fiveHours)
      window(id, period: .weekly)
    }.padding(.vertical, 10).contentShape(Rectangle())
      .accessibilityElement(children: .contain)
  }

  private var antigravityRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        providerHeading(.antigravity)
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
          }.padding(.vertical, 10).help(store.hoverSummary(.antigravity))
        }
      } else {
        ForEach(store.antigravityModels) { metric in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(L10n.text(metric.name)).font(.system(size: 11, weight: .medium))
              Text(L10n.text("Model quota · window unknown")).font(.system(size: 10))
                .foregroundStyle(
                  .secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
              value(
                store.modelLabel(metric), tone: store.tone(.antigravity, metric: metric),
                provider: .antigravity)
              Text(UsageDisplay.resetCountdown(metric.resetAt, now: store.now)).font(
                .system(size: 10)
              )
              .foregroundStyle(.secondary)
            }
          }.padding(.vertical, 10).help(store.hoverSummary(.antigravity))
        }
      }
    }
  }

  private var copilotRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        providerHeading(.copilot)
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(L10n.text("Monthly"))
          if let status = store.serviceStatusLabel(.copilot) { Text(status) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
      }.padding(.top, 10).padding(.bottom, 6)
      ForEach(store.copilotMetrics) { metric in
        HStack {
          VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text(metric.name)).font(.system(size: 11, weight: .medium))
            if !metric.unlimited {
              Text(store.countLabel(metric)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 5) {
            value(
              store.metricLabel(.copilot, metric: metric),
              tone: store.tone(.copilot, metric: metric), provider: .copilot)
            if !metric.unlimited {
              Text(UsageDisplay.resetCountdown(metric.resetAt, now: store.now)).font(
                .system(size: 10)
              )
              .foregroundStyle(.secondary)
            }
          }
        }.padding(.vertical, 10).help(store.hoverSummary(.copilot))
      }
    }
  }

  private func providerHeading(_ id: ProviderID) -> some View {
    let selected = store.settings.showUsage && store.settings.selectedProvider == id
    return HStack(spacing: 5) {
      Button {
        detailProvider = id
      } label: {
        Text(id.name).font(.system(size: 13, weight: .medium)).fixedSize()
      }.buttonStyle(.plain)
        .help(store.hoverSummary(id))
        .accessibilityLabel(L10n.format("View %@ details", id.name))
      Button {
        store.showProviderInMenuBar(id)
      } label: {
        Image(systemName: selected ? "pin.fill" : "pin")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .frame(width: 22, height: 22)
          .background(
            selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 5))
      }.buttonStyle(.plain).disabled(!store.canEditSettings)
        .help(
          selected
            ? L10n.text("Shown in the menu bar") : L10n.format("Show %@ in the menu bar", id.name)
        )
        .accessibilityLabel(L10n.format("Show %@ in the menu bar", id.name))
        .accessibilityValue(selected ? L10n.text("Selected") : L10n.text("Not selected"))
    }
  }

  private func value(_ label: String, tone: UsageTone, provider: ProviderID) -> some View {
    Button {
      detailProvider = provider
    } label: {
      Text(label).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit()
        .foregroundStyle(usageColor(tone))
    }.buttonStyle(.plain).help(L10n.text("Click for full details"))
      .accessibilityLabel(L10n.format("View %@ details", provider.name))
      .accessibilityValue(label)
  }

  private func usageColor(_ tone: UsageTone) -> Color {
    switch tone {
    case .unknown: .secondary
    case .low: Color(nsColor: .systemGreen)
    case .medium: Color(nsColor: .systemOrange)
    case .high: Color(nsColor: .systemRed)
    }
  }

  private func window(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> some View {
    VStack(alignment: .trailing, spacing: 5) {
      value(
        store.label(id, period: period, scope: scope),
        tone: store.tone(id, metric: store.metric(id, period: period, scope: scope)), provider: id)
      Text(store.resetLabel(id, period: period, scope: scope)).font(.system(size: 10))
        .monospacedDigit().foregroundStyle(.secondary)
    }.frame(width: 105, alignment: .trailing)
      .help(store.hoverSummary(id))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        "\(id.name), \(period == .fiveHours ? L10n.text("5 hours") : L10n.text("Weekly")), \(store.label(id, period: period, scope: scope)), \(store.resetLabel(id, period: period, scope: scope))"
      )
  }

  private func action(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(text, systemImage: symbol).font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity).padding(.vertical, 8).contentShape(Rectangle())
    }.buttonStyle(PanelActionStyle())
  }
}

/// Full details stay inside the screen-positioned popover, with wrapping and scrolling.
struct UsageDetailsView: View {
  @ObservedObject var store: AppStore
  let provider: ProviderID
  var maximumContentHeight: () -> CGFloat
  var back: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button(action: back) {
          Label(L10n.text("Back"), systemImage: "chevron.left")
        }.buttonStyle(.plain)
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text(provider.name).font(.headline)
          Text(L10n.text("Usage details")).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(16)
      Divider()
      ScrollView {
        Text(store.detailsText(provider)).font(.system(size: 12))
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      }.frame(height: min(520, maximumContentHeight()))
      Divider()
      HStack {
        Text(store.updateLabel(provider)).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(L10n.text("Refresh")) { store.refresh(provider) }
          .disabled(
            store.states[provider]?.refreshing == true
              || store.settings.services.first(where: { $0.provider == provider })?.enabled != true)
      }.padding(12)
    }.frame(width: 380)
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
        Picker(L10n.text("Display"), selection: binding(\.showUsage)) {
          Text(L10n.text("Default icon")).tag(false)
          Text(L10n.text("Service usage")).tag(true)
        }
        Picker(
          L10n.text("Service"),
          selection: Binding(
            get: { store.settings.selectedProvider }, set: { store.selectProvider($0) })
        ) {
          ForEach(ProviderID.allCases) { Text($0.name).tag($0) }
        }.disabled(!store.settings.showUsage)
        Picker(
          L10n.text("Metric"),
          selection: Binding(
            get: { store.settings.selectedMetricID }, set: { store.selectMetric($0) })
        ) {
          let metrics = store.states[store.settings.selectedProvider]?.snapshot?.metrics ?? []
          if !metrics.contains(where: { $0.id == store.settings.selectedMetricID }) {
            Text(L10n.text("Awaiting selected metric")).tag(store.settings.selectedMetricID)
          }
          ForEach(metrics) { metric in Text(L10n.text(metric.name)).tag(metric.id) }
        }.disabled(!store.settings.showUsage)
        Picker(L10n.text("Values"), selection: binding(\.showRemaining)) {
          Text(L10n.text("Used")).tag(false)
          Text(L10n.text("Remaining")).tag(true)
        }
        Text(
          L10n.text(
            "Service usage shows the service icon and percentage. Select a metric after its first successful refresh."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
        if let snapshot = store.states[store.settings.selectedProvider]?.snapshot,
          store.settings.selectedAccountID != nil,
          snapshot.accountID != store.settings.selectedAccountID
        {
          Text(L10n.text("The signed-in account changed. Choose a metric to bind the new account."))
            .foregroundStyle(.orange)
        }
      }.formStyle(.grouped).tabItem {
        Label(L10n.text("Menu Bar"), systemImage: "menubar.rectangle")
      }
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
                .disabled(index == 0).help(L10n.text("Move up"))
                Button {
                  store.move(service.provider, by: 1)
                } label: {
                  Image(systemName: "arrow.down")
                }
                .disabled(index == store.settings.services.count - 1).help(L10n.text("Move down"))
              }
              HStack {
                Toggle(L10n.text("Show in list"), isOn: serviceBinding(service.provider, \.visible))
                Toggle(
                  L10n.text("Enable monitoring"), isOn: serviceBinding(service.provider, \.enabled))
              }
              HStack {
                TextField(
                  sourcePlaceholder(service.provider),
                  text: serviceBinding(service.provider, \.sourcePath)
                )
                .textFieldStyle(.roundedBorder)
                Button(L10n.text("Choose…")) { choose(service.provider) }
              }
              Text(sourceDescription(service.provider)).font(.caption).foregroundStyle(.secondary)
              HStack {
                Button(L10n.text("Validate / Refresh")) { store.refresh(service.provider) }
                  .disabled(
                    !service.enabled)
                Button(L10n.text("Use default source")) {
                  store.editService(service.provider) { $0.sourcePath = "" }
                }
              }
              Text(store.detailsText(service.provider)).font(.caption).textSelection(.enabled)
              Divider()
            }
          }
        }.padding(16)
      }.tabItem { Label(L10n.text("Services"), systemImage: "list.bullet") }
      Form {
        Picker(L10n.text("Refresh interval"), selection: binding(\.refreshMinutes)) {
          ForEach([1, 3, 5, 10], id: \.self) { Text(L10n.format("%@ minutes", String($0))).tag($0) }
        }
        Text(
          L10n.text(
            "Provider minimums and rate-limit cooldowns take precedence. Claude Code refreshes at most every 5 minutes automatically."
          )
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          L10n.text("Launch at login"),
          isOn: Binding(get: { loginStatus == .enabled }, set: { setLogin($0) }))
        if loginStatus == .requiresApproval {
          Button(L10n.text("Approve in Login Items…")) {
            SMAppService.openSystemSettingsLoginItems()
          }
        }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        Text(
          L10n.text("Local usage monitoring only. Credentials remain in their original sources.")
        ).font(
          .caption
        ).foregroundStyle(.secondary)
      }.formStyle(.grouped).tabItem { Label(L10n.text("General"), systemImage: "gearshape") }
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
      get: {
        guard let service = store.settings.services.first(where: { $0.provider == id }) else {
          var unavailable = ServiceConfiguration(provider: id)
          unavailable.enabled = false
          unavailable.visible = false
          return unavailable[keyPath: key]
        }
        return service[keyPath: key]
      },
      set: { value in store.editService(id) { $0[keyPath: key] = value } })
  }
  private func sourcePlaceholder(_ id: ProviderID) -> String {
    switch id {
    case .codex: L10n.text("Default: ~/.codex/auth.json")
    case .claude: L10n.text("Auto-detect claude executable")
    case .antigravity: L10n.text("Auto-detect running Antigravity (optional OAuth JSON)")
    case .copilot: L10n.text("Auto-detect Copilot editor / CLI sign-in")
    }
  }
  private func sourceDescription(_ id: ProviderID) -> String {
    switch id {
    case .codex:
      L10n.text(
        "Uses a subscription auth.json file (including CODEX_HOME). Tokens are never renewed by LLM Meter."
      )
    case .claude:
      L10n.text(
        "Requires Claude Code 2.1.285+. Runs its read-only /usage command; no model requests or tools."
      )
    case .antigravity:
      L10n.text(
        "Leave blank to read the running Antigravity app's local quota status. Keep it open and signed in. Optional fallback: an OAuth JSON with a current access_token. Quota groups and model metrics can be selected in Menu Bar."
      )
    case .copilot:
      L10n.text(
        "Reads github.com Copilot editor sign-in or Copilot CLI config and an already accessible Keychain token. Optional single-account OAuth JSON. Monthly quotas retain AI-credit/request units; no login, token renewal, or inference requests."
      )
    }
  }
  private func choose(_ id: ProviderID) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message =
      id == .claude
      ? L10n.text("Choose the Claude Code executable")
      : L10n.text("Choose an existing sign-in JSON file")
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
        L10n.text(
          "Could not change launch at login. Check System Settings → General → Login Items.")
    }
    loginStatus = SMAppService.mainApp.status
  }
}
