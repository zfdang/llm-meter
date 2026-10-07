# LLM Meter

A native macOS menu bar utility for LLM usage and remaining allowances. Requires Apple Silicon and macOS 13 or later.

Click the circular gauge to see a compact **5h / Weekly** list. Settings controls which services appear, their order, used versus remaining values, and whether the menu bar shows the default icon or one selected usage metric.

English is the project's working language for documentation, code comments, and development materials.

## Build and Run

Use Xcode 16 or later with Swift 6. If your active developer directory points to Command Line Tools, select Xcode for the command without changing system settings:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
make test
make app
open "build/LLM Meter.app"
```

`make app` creates an arm64 application with a local ad-hoc signature and a `build/LLM-Meter-arm64.zip` archive that preserves executable permissions. `SIGNING_IDENTITY` can supply a Developer ID identity; notarization is a separate distribution step. For launch at login, place the bundle in a stable location such as `/Applications` before enabling the setting.

## Providers

| Provider | Source | Current support |
| --- | --- | --- |
| Codex | Existing subscription `auth.json`, using `CODEX_HOME` or `~/.codex` by default | Account-level quota windows; live read verified during development |
| Claude Code | Installed `claude` executable, version 2.1.285 or newer | Read-only `/usage` parsing and account checks; subscription sign-in required |
| Antigravity | Existing single-account OAuth JSON with a current `access_token` | Model-scoped quotas; choose a file in Settings, then select a model metric for the menu bar |

Choose a custom Codex auth file or Claude executable in Settings if automatic discovery does not locate your source. Antigravity's current integration requires an OAuth JSON source; automatic discovery of the desktop client's private sign-in storage is not implemented. No integration copies or rotates refresh tokens. Open the original tool to renew expired credentials.

Unknown or unsupported periods display `—`. Antigravity model quotas are available in row tooltips and Settings; they are not relabeled as 5h or Weekly without source evidence. Claude Code and Antigravity have fixture coverage; their live subscription reads still require suitable local login sources.

## Diagnostics

```sh
"build/LLM Meter.app/Contents/MacOS/LLMMeter" --diagnose
```

This reads enabled sources and prints success counts or sanitized errors without storing results or printing credentials. `--settings` opens Settings on launch; `--panel` opens the usage panel.

## Documentation

- [Design](docs/design.md): Product goals, interaction, architecture, and acceptance criteria.
- [Development](docs/development.md): Module boundaries, provider setup, persistence, checks, and current limitations.
