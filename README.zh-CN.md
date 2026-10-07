# LLM Meter

[English](README.md) | **简体中文**

一个原生 macOS 菜单栏工具，用于查看大语言模型服务的用量和剩余额度。需要 Apple Silicon 芯片和 macOS 13 或更高版本。

<img src="docs/images/usage-panel-zh.png" alt="LLM Meter 简体中文用量面板" width="420">
<img src="docs/images/usage-panel-dark.png" alt="LLM Meter 深色模式用量面板（英文界面）" width="420">

*截图展示原生界面，额度为虚构示例。各服务可显示的统计周期取决于数据来源。*

点击菜单栏图标或用量数值，即可查看简洁的 **5 小时 / 每周**用量列表。在设置中可以选择要显示的服务、排列顺序、显示已用或剩余比例，以及让菜单栏显示默认图标，或某个服务的图标和用量百分比。

点击服务名称或用量数值，可在高度受限、支持滚动的面板中查看完整详情。文本自动换行、可选中复制，并随刷新更新。点击**返回**回到概览；悬停提示只显示简短摘要。面板底部也会提示这一操作。

点击服务名称旁的小图钉，可以立即将该服务切换为菜单栏显示对象。蓝色实心图钉表示当前选择，灰色轮廓图钉表示其他服务。切换时会选中该服务第一个可用的用量指标；点击当前已选服务则保留原先的指标选择。

每个用量周期都会显示重置倒计时。底部显示已启用且可见服务中最近一次成功更新的时间；悬停其上可查看各服务距上次更新的时间。打开服务详情可以查看准确的重置和读取时间、脱敏账号信息、订阅方案及错误。未知的重置时间不会被推算；重置时间已过时，会显示“等待更新”，直到数据来源确认新的额度。目前的适配器不显示重置抵扣额度（reset credits）。

项目的工作语言为英文，代码注释和开发文档使用英文。本页提供中文使用说明。

## 构建与运行

使用 Xcode 16 或更高版本及 Swift 6。如果当前开发工具目录指向 Command Line Tools，可以通过以下方式为命令指定 Xcode，无需修改系统设置：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make test
make app
open "build/LLM Meter.app"
```

`make app` 会生成采用本地 ad hoc 签名的 arm64 应用，以及保留可执行权限的 `build/LLM-Meter-arm64.zip` 压缩包。可以通过 `SIGNING_IDENTITY` 指定 Developer ID 签名身份；公证需要另行完成。若要启用登录时启动，请先将应用放在稳定的位置，例如 `/Applications`。

## GitHub 构建与发布

[CI](https://github.com/zfdang/llm-meter/actions/workflows/ci.yml) 会在拉取请求和推送到 main 时检查 Swift 格式并运行测试。[Package macOS app](https://github.com/zfdang/llm-meter/actions/workflows/package.yml) 会在拉取请求、main 更新和手动触发时构建并验证 arm64 应用。

每次合并到 `main` 都会自动发布一个版本。标签由构建日期和提交的短哈希组成，日期使用 `Asia/Shanghai` 时区，例如 `v2026.10.07-3e5e7de`。每个版本包含 `LLM-Meter-arm64.zip` 及其 SHA-256 校验文件，应用内的版本号与标签一致。工作流的 `LLM-Meter-arm64` 构建产物会保留相同文件 30 天；重新运行同一提交会更新已有版本的附件，而不会创建重复版本。

从[最新版本](https://github.com/zfdang/llm-meter/releases/latest)下载 ZIP 文件，并校验：

```sh
shasum -a 256 -c LLM-Meter-arm64.zip.sha256
```

这些开发构建采用 ad hoc 签名，**未经 Apple 公证**。首次启动时，macOS 可能会阻止运行：可以右键点击应用并选择“打开”，或移除隔离属性。面向公众分发需要 Developer ID 签名和 Apple 公证。

## 支持的服务

| 服务 | 数据来源 | 当前支持情况 |
| --- | --- | --- |
| Codex | 已有订阅账号的 `auth.json`，默认使用 `CODEX_HOME` 或 `~/.codex` | 账号级额度周期；开发过程中已验证真实读取 |
| Claude Code | 已安装的 `claude` 可执行文件，版本需为 2.1.285 或更新 | 只读解析 `/usage` 并检查账号；需要登录订阅账号 |
| Antigravity | 运行中的桌面客户端本地状态接口；可选用包含当前令牌的 OAuth JSON 作为回退来源 | 按额度组分别显示 5 小时 / 每周用量，可回退到模型额度，并在菜单栏显示所选指标；已验证真实本地读取 |
| GitHub Copilot | 已有编辑器登录信息或 Copilot CLI 配置，以及可访问的钥匙串令牌 | 每月 AI Credits / 高级请求、聊天和代码补全，支持显示无限额度；已验证真实读取 |

如果自动发现未找到数据来源，可以在设置中指定 Codex 认证文件或 Claude 可执行文件。使用 Antigravity 时，将来源路径留空（或点击**使用默认来源**），保持 Antigravity 应用运行且已登录，然后刷新。工具会发现客户端的本机回环语言服务器并读取状态，无需浏览器 Cookie、导出凭证或单独登录。自定义 OAuth JSON 仍可作为可选回退来源。各集成均不会复制或轮换刷新令牌；凭证过期时，请打开原工具续期。

Copilot 支持 github.com 账号。它会读取已有编辑器的 apps.json / hosts.json 或 CLI 的 config.json（包括 JSONC），不会弹出钥匙串访问授权提示。如果自动发现无法找到可访问的凭证，可以选择一个单账号 OAuth JSON 文件。Copilot 使用单独的每月统计区域，不会虚构 5 小时 / 每周统计周期。

Copilot 额度读取依赖 GitHub 未公开的 `/copilot_internal/user` 接口。GitHub 可能随时修改或移除该接口。如果访问或解析失败，应用会显示错误，并保留上次成功读取的数据，按照正常规则标记陈旧或过期状态；届时可能需要更新集成实现。

未知或不支持的周期显示为 `—`。Antigravity 的各额度组分别保留 5 小时 / 每周数值；如果客户端只提供模型额度，面板会逐个显示模型，并将统计周期标记为未知。所有指标都可以在详情面板、设置及菜单栏指标选择器中查看。Claude Code 已有测试样例覆盖；真实订阅读取仍需要合适的本地登录来源进行验证。

## 诊断

```sh
"build/LLM Meter.app/Contents/MacOS/LLMMeter" --diagnose
```

该命令读取已启用的数据来源，输出成功数量或经过脱敏的错误，不保存结果，也不打印凭证。`--settings` 可在启动时打开设置；`--panel` 可在启动时打开用量面板。

## 文档

以下开发文档使用英文：

- [设计文档](docs/design.md)：产品目标、交互、架构和验收标准。
- [开发文档](docs/development.md)：模块边界、服务配置、持久化、检查流程和当前限制。

## 图标来源

服务图标改编自采用 MIT 许可证的 [LobeHub Icons](https://github.com/lobehub/lobe-icons)。原始 SVG 和许可证随应用一起打包。各标识用于识别对应服务。

## 界面语言

界面跟随 macOS“系统设置 → 通用 → 语言与地区”中的首选语言。简体中文（`zh-Hans`，包括中国大陆和新加坡地区变体）显示中文，其他语言均显示英文。修改系统语言后，请重新启动 LLM Meter。服务和模型名称保留数据来源提供的原始名称。设置和缓存读数不受语言选择影响。

<details>
<summary>简体中文界面预览</summary>

![简体中文用量面板](docs/images/usage-panel-zh.png)

</details>

<details>
<summary>默认图标与菜单栏图标大小对比</summary>

默认图标采用完整的圆形仪表，在相同的 18 点空间内呈现更大的视觉尺寸。模板渲染会自动适配菜单栏的浅色或深色外观。

![旧版与新版默认图标及服务图标对比](docs/images/menu-bar-icons.png)

</details>

<details>
<summary>可滚动的服务详情</summary>

![支持文本换行和滚动的服务详情](docs/images/usage-details.png)

</details>
