# LLM Meter

A native macOS menu bar utility for LLM usage and remaining allowances. Requires Apple Silicon and macOS 13 or later.

Click the meter icon or usage label to see a compact **5h / Weekly** list. Settings controls which services appear, their order, used versus remaining values, and whether the menu bar shows the default icon or one selected usage metric as text only (for example, `CX 42%`).

Each usage window includes a reset countdown, and each service shows the age of its last successful update. Hover over a row for exact reset and reading times, masked account details, plan, and errors. Unknown reset times stay unknown; a passed reset shows “Awaiting update” until the source confirms a new allowance. Reset credits are not displayed by the current adapters.

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
| Antigravity | Running desktop client's local status interface; optional current-token OAuth JSON fallback | Separate quota-group 5h/Weekly rows, model quota fallback, and a selected metric in the menu bar; live local read verified |

Choose a custom Codex auth file or Claude executable in Settings if automatic discovery does not locate your source. For Antigravity, leave the source path blank (or click **Use default source**), keep the Antigravity app open and signed in, and refresh. The monitor discovers the client's loopback language server and reads status without browser cookies, credential exports, or its own login flow. A custom OAuth JSON remains an optional fallback. No integration copies or rotates refresh tokens. Open the original tool to renew expired credentials.

Unknown or unsupported periods display `—`. Antigravity's quota groups keep separate 5h/Weekly values; when the client supplies only model quotas, the panel shows each model with an unknown window duration. All metrics are available in tooltips, Settings, and the menu bar metric picker. Claude Code has fixture coverage; its live subscription read still requires a suitable local login source.

## Diagnostics

```sh
"build/LLM Meter.app/Contents/MacOS/LLMMeter" --diagnose
```

This reads enabled sources and prints success counts or sanitized errors without storing results or printing credentials. `--settings` opens Settings on launch; `--panel` opens the usage panel.

## Documentation

- [Design](docs/design.md): Product goals, interaction, architecture, and acceptance criteria.
- [Development](docs/development.md): Module boundaries, provider setup, persistence, checks, and current limitations.
