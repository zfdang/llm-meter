import Foundation

/// UI language follows the first system preference. Only Simplified Chinese is translated.
/// Explicit script wins over region (zh-Hant-CN remains English).
public enum L10n {
  public static func usesSimplifiedChinese(_ languages: [String]) -> Bool {
    guard let first = languages.first else { return false }
    let locale = Locale(identifier: first)
    guard locale.language.languageCode?.identifier == "zh" else { return false }
    if let script = locale.language.script?.identifier { return script == "Hans" }
    return ["CN", "SG"].contains(locale.region?.identifier ?? "")
  }

  public static var locale: Locale {
    Locale(identifier: usesSimplifiedChinese(Locale.preferredLanguages) ? "zh_Hans_CN" : "en_US")
  }

  public static func text(_ english: String, languages: [String] = Locale.preferredLanguages)
    -> String
  {
    usesSimplifiedChinese(languages) ? translations[english] ?? english : english
  }

  public static func format(
    _ english: String, _ arguments: String..., languages: [String] = Locale.preferredLanguages
  ) -> String {
    let parts = text(english, languages: languages).components(separatedBy: "%@")
    var result = parts[0]
    for index in 1..<parts.count {
      result += (index <= arguments.count ? arguments[index - 1] : "%@") + parts[index]
    }
    return result
  }

  private static let translations: [String: String] = [
    "Usage overview": "用量概览",
    "Remaining": "剩余",
    "Used": "已用",
    "SERVICE": "服务",
    "5 HOURS": "5 小时",
    "WEEKLY": "每周",
    "No services selected": "未选择服务",
    "Choose which LLMs to display in Settings.": "请在设置中选择要显示的服务。",
    "Refreshing…": "正在刷新…",
    "Refresh": "刷新",
    "Settings": "设置",
    "Quit": "退出",
    "Model quota · window unknown": "模型额度 · 周期未知",
    "Monthly": "每月",
    "Shown in the menu bar": "已显示在菜单栏",
    "Selected": "已选中",
    "Not selected": "未选中",
    "Display": "显示方式",
    "Default icon": "默认图标",
    "Service usage": "服务用量",
    "Service": "服务",
    "Metric": "指标",
    "Awaiting selected metric": "等待所选指标",
    "Values": "数值",
    "Menu Bar": "菜单栏",
    "Services": "服务",
    "General": "通用",
    "Move up": "上移",
    "Move down": "下移",
    "Show in list": "在列表中显示",
    "Enable monitoring": "启用监测",
    "Choose…": "选择…",
    "Validate / Refresh": "验证 / 刷新",
    "Use default source": "使用默认来源",
    "Refresh interval": "刷新间隔",
    "Launch at login": "登录时启动",
    "Approve in Login Items…": "在登录项中批准…",
    "Local usage monitoring only. Credentials remain in their original sources.":
      "仅在本地监测用量。凭证保留在原始来源中。",
    "Service usage shows the service icon and percentage. Select a metric after its first successful refresh.":
      "服务用量显示服务图标和百分比。首次成功刷新后即可选择指标。",
    "The signed-in account changed. Choose a metric to bind the new account.":
      "登录账号已更改。请选择指标以绑定新账号。",
    "Provider minimums and rate-limit cooldowns take precedence. Claude Code refreshes at most every 5 minutes automatically.":
      "优先遵守服务的最短刷新间隔和限流冷却时间。Claude Code 自动刷新间隔至少为 5 分钟。",
    "Default: ~/.codex/auth.json": "默认：~/.codex/auth.json",
    "Auto-detect claude executable": "自动检测 claude 可执行文件",
    "Auto-detect running Antigravity (optional OAuth JSON)": "自动检测运行中的 Antigravity（可选 OAuth JSON）",
    "Auto-detect Copilot editor / CLI sign-in": "自动检测 Copilot 编辑器 / CLI 登录",
    "Uses a subscription auth.json file (including CODEX_HOME). Tokens are never renewed by LLM Meter.":
      "读取订阅账号的 auth.json 文件（支持 CODEX_HOME）。LLM Meter 不会续期令牌。",
    "Requires Claude Code 2.1.285+. Runs its read-only /usage command; no model requests or tools.":
      "需要 Claude Code 2.1.285 或更新版本。执行只读 /usage 命令，不发起模型请求或调用工具。",
    "Leave blank to read the running Antigravity app's local quota status. Keep it open and signed in. Optional fallback: an OAuth JSON with a current access_token. Quota groups and model metrics can be selected in Menu Bar.":
      "留空以读取运行中的 Antigravity 的本地额度状态。请保持应用运行并登录。可选备用来源：包含有效 access_token 的 OAuth JSON。可在菜单栏设置中选择额度组和模型指标。",
    "Reads github.com Copilot editor sign-in or Copilot CLI config and an already accessible Keychain token. Optional single-account OAuth JSON. Monthly quotas retain AI-credit/request units; no login, token renewal, or inference requests.":
      "读取 github.com 的 Copilot 编辑器登录信息，或 Copilot CLI 配置及已可访问的钥匙串令牌。支持单账号 OAuth JSON。月度额度保留 AI 积分或请求次数单位；不会登录、续期令牌或发起推理请求。",
    "Choose the Claude Code executable": "选择 Claude Code 可执行文件",
    "Choose an existing sign-in JSON file": "选择现有登录 JSON 文件",
    "Could not change launch at login. Check System Settings → General → Login Items.":
      "无法更改登录时启动。请检查系统设置 → 通用 → 登录项。",
    "Monitoring off": "监测已关闭",
    "Not read yet": "尚未读取",
    "Unable to refresh": "无法刷新",
    "Not updated yet": "尚未更新",
    "Monitoring disabled": "监测已禁用",
    "Previous account reading · awaiting confirmation": "上次账号读数 · 等待确认",
    "Unknown": "未知",
    "Unlimited": "不限量",
    "Monthly allowance": "月度额度",
    "remaining": "剩余",
    "used": "已用",
    "Awaiting update after reset": "重置后等待更新",
    "Retained reading · awaiting confirmation": "保留的读数 · 等待确认",
    "Quota groups are shown separately. Model quotas have no assumed window duration.":
      "额度组分别显示。模型额度不会被假定为特定周期。",
    "Reset unknown": "重置时间未知",
    "Awaiting update": "等待更新",
    "Resets <1m": "不到 1 分钟后重置",
    "Updated just now": "刚刚更新",
    "LLM Meter · Click to view usage": "LLM Meter · 点击查看用量",
    "LLM Meter Settings": "LLM Meter 设置",
    "Settings…": "设置…",
    "Quit LLM Meter": "退出 LLM Meter",
    "Window": "窗口",
    "Close": "关闭",
    "Rate limited. Waiting before retrying.": "已被限流，等待后重试。",
    "Could not reach the usage source.": "无法连接用量来源。",
    "The usage source timed out.": "用量来源响应超时。",
    "Refresh cancelled.": "刷新已取消。",
    "AI Credits": "AI 积分",
    "AI credits": "AI 积分",
    "Premium requests": "高级请求",
    "Chat requests": "聊天请求",
    "Completions": "补全",
    "completions": "次补全",
    "requests": "次请求",
    "Green: under 50% used. Orange: 50% to below 80% used. Red: 80% or more used. Colors keep the same meaning when displaying remaining allowance. Retained or unknown readings are gray.":
      "绿色：已用不足 50%。橙色：已用 50% 至不足 80%。红色：已用 80% 或以上。显示剩余额度时，颜色含义保持不变。保留或未知的读数显示为灰色。",
    "Show %@ in the menu bar": "在菜单栏显示 %@",
    "%@ minutes": "%@ 分钟",
    "Plan: %@": "套餐：%@",
    "Read %@": "读取时间：%@",
    "Resets in %@": "%@ 后重置",
    "Updated %@ ago": "%@ 前更新",
    "%@ left": "剩余 %@",
    "Most recent successful read among visible enabled services.": "已启用且可见服务中最近一次成功读取的时间。",
    "999d+": "超过 999 天",
    "%@d %@h": "%@ 天 %@ 小时",
    "%@h %@m": "%@ 小时 %@ 分钟",
    "%@m": "%@ 分钟",
    "5 hours": "5 小时",
    "Weekly": "每周",
    "5h": "5 小时",
    "Quota": "额度",
    "Cached reading · awaiting confirmation": "缓存读数 · 等待确认",
    "Reading is stale": "读数已陈旧",
    "Copilot rejected the existing sign-in. Sign in through Copilot, then refresh.":
      "Copilot 拒绝了现有登录凭证。请通过 Copilot 登录后刷新。",
    "Cannot confirm the Copilot account. Sign in through Copilot, then refresh.":
      "无法确认 Copilot 账号。请通过 Copilot 登录后刷新。",
    "Copilot sign-in changed during refresh. Refresh again.": "刷新期间 Copilot 登录信息发生变化。请再次刷新。",
    "Unrecognized Copilot sign-in JSON.": "无法识别 Copilot 登录 JSON。",
    "This Copilot adapter currently supports github.com accounts.":
      "目前仅支持 github.com 的 Copilot 账号。",
    "Multiple Copilot accounts found. Choose a single-account OAuth JSON source in Settings.":
      "发现多个 Copilot 账号。请在设置中选择单账号 OAuth JSON 来源。",
    "Sign in through a Copilot editor or Copilot CLI, then refresh. A single-account OAuth JSON source can also be selected in Settings. Keychain reads do not prompt for access.":
      "请通过 Copilot 编辑器或 Copilot CLI 登录后刷新。也可在设置中选择单账号 OAuth JSON 来源。读取钥匙串不会弹出访问请求。",
    "Invalid Copilot JSON comment.": "Copilot JSON 注释无效。",
    "Usage response is too large.": "用量响应过大。",
    "Sign in again through the original tool, then refresh.": "请通过原始工具重新登录后刷新。",
    "The usage endpoint is unavailable for this source.": "此来源的用量接口不可用。",
    "Cannot start the configured CLI executable.": "无法启动配置的 CLI 可执行文件。",
    "Cannot allocate CLI launch arguments.": "无法分配 CLI 启动参数。",
    "Cannot wait for the CLI executable.": "无法等待 CLI 进程结束。",
    "Cannot create a temporary output file.": "无法创建临时输出文件。",
    "CLI output exceeded the size limit.": "CLI 输出超过大小限制。",
    "Unrecognized Copilot quota response.": "无法识别 Copilot 额度响应。",
    "Copilot did not report any supported quota snapshots.": "Copilot 未返回支持的额度数据。",
    "Sign in through the Antigravity app, then refresh.": "请通过 Antigravity 应用登录后刷新。",
    "Unrecognized Antigravity quota summary.": "无法识别 Antigravity 额度汇总。",
    "Invalid Antigravity quota fraction.": "Antigravity 额度比例无效。",
    "Invalid or unsupported cache. Original file preserved.": "缓存无效或不受支持。原文件已保留。",
    "Could not create a storage file.": "无法创建存储文件。",
    "Could not replace a storage file.": "无法替换存储文件。",
    "Unsupported settings version. Original file preserved.": "设置版本不受支持。原文件已保留。",
    "Invalid settings. Original file preserved.": "设置无效。原文件已保留。",
    "Unrecognized Codex usage response.": "无法识别 Codex 用量响应。",
    "Codex did not return quota windows.": "Codex 未返回额度周期。",
    "No Codex quota windows are available for this account.": "此账号没有可用的 Codex 额度周期。",
    "Claude Code requires sign-in. Run claude in Terminal, then refresh.":
      "Claude Code 需要登录。请在终端运行 claude 后刷新。",
    "Claude Code returned no recognized usage windows. Check its version and sign-in.":
      "Claude Code 未返回可识别的用量周期。请检查版本和登录状态。",
    "Unrecognized Antigravity quota response.": "无法识别 Antigravity 额度响应。",
    "No Antigravity model quotas were returned.": "未返回 Antigravity 模型额度。",
    "The source returned an invalid usage percentage.": "来源返回了无效的用量百分比。",
    "Open Antigravity and sign in, then refresh. Automatic monitoring reads its running local language server.":
      "请打开 Antigravity 并登录后刷新。自动监测读取运行中的本地语言服务器。",
    "Antigravity restarted during refresh. Refresh again.": "刷新期间 Antigravity 已重启。请再次刷新。",
    "Antigravity account changed during refresh. Refresh again.": "刷新期间 Antigravity 账号发生变化。请再次刷新。",
    "Antigravity did not report any quota values for this account.": "Antigravity 未返回此账号的额度数值。",
    "Cannot read Antigravity's local status interface. Keep Antigravity running and signed in, then refresh.":
      "无法读取 Antigravity 本地状态接口。请保持 Antigravity 运行并登录后刷新。",
    "The source returned a mismatched provider.": "来源返回的服务类型不匹配。",
    "The credential file is too large.": "凭证文件过大。",
    "Cannot read the sign-in source. Choose a file in Settings or sign in through the original tool.":
      "无法读取登录来源。请在设置中选择文件，或通过原始工具登录。",
    "Unrecognized Codex sign-in file.": "无法识别 Codex 登录文件。",
    "A Codex subscription sign-in is required; API key authentication has no subscription quota.":
      "需要 Codex 订阅账号登录；API 密钥认证没有订阅额度。",
    "Codex sign-in expired. Open Codex to renew it, then refresh.":
      "Codex 登录已过期。请打开 Codex 更新登录后刷新。",
    "Codex account changed during refresh. Refresh again.": "刷新期间 Codex 账号发生变化。请再次刷新。",
    "Sign in to a Claude Code subscription in Terminal, then refresh.":
      "请在终端登录 Claude Code 订阅账号后刷新。",
    "Claude Code 2.1.285 or newer is required for read-only print-mode usage.":
      "只读打印模式用量查询需要 Claude Code 2.1.285 或更新版本。",
    "Claude Code could not read usage. Check its sign-in in Terminal.":
      "Claude Code 无法读取用量。请在终端检查登录状态。",
    "Claude Code account changed during refresh. Refresh again.": "刷新期间 Claude Code 账号发生变化。请再次刷新。",
    "Choose a single-account Antigravity OAuth JSON file containing access_token and project_id.":
      "请选择包含 access_token 和 project_id 的单账号 Antigravity OAuth JSON 文件。",
    "An Antigravity access token is required. Refresh-only exports are unsupported.":
      "需要 Antigravity 访问令牌。不支持仅包含刷新令牌的导出文件。",
    "Cannot establish Antigravity account identity.": "无法确认 Antigravity 账号身份。",
    "Antigravity did not expose a project. Choose a source with project_id.":
      "Antigravity 未提供项目。请选择包含 project_id 的来源。",
    "Antigravity source changed during refresh. Refresh again.": "刷新期间 Antigravity 来源发生变化。请再次刷新。",
    "Cannot read %@. Original file preserved.": "无法读取 %@。原文件已保留。",
    "Could not save %@. Check folder permissions.": "无法保存 %@。请检查文件夹权限。",
    "The configured %@ executable is unavailable.": "配置的 %@ 可执行文件不可用。",
    "%@ was not found. Choose its executable in Settings.": "未找到 %@。请在设置中选择其可执行文件。",
  ]
}
