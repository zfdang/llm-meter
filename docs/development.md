# Development Guide

## Implementation

The project is a Swift 6 package with an AppKit/SwiftUI executable and a reusable core library. It targets macOS 13+ on Apple Silicon.

| Path | Responsibility |
| --- | --- |
| `Sources/LLMMeterApp/main.swift` | Application lifecycle, menu bar drawing, popover, Settings window, and diagnostics |
| `Sources/LLMMeterApp/Views.swift` | Compact usage rows and native Settings tabs |
| `Sources/LLMMeterApp/AppStore.swift` | MainActor UI state, display selections, storage, and sleep/wake handling |
| `Sources/LLMMeterCore/Models.swift` | Settings, account snapshots, metrics, and freshness semantics |
| `Sources/LLMMeterCore/Providers.swift` | Codex, Claude Code, and Antigravity sources; credential reading and identity checks |
| `Sources/LLMMeterCore/Parsers.swift` | Provider response normalization and reset-date parsing |
| `Sources/LLMMeterCore/RefreshCoordinator.swift` | Per-source request coalescing, cooldowns, backoff, reset checks, and late-result rejection |
| `Sources/LLMMeterCore/Persistence.swift` | Versioned JSON and atomic, private local storage |
| `Sources/LLMMeterCore/Transport.swift` | Ephemeral HTTP requests and bounded CLI execution |

No external package dependencies are required. ProviderRegistry accepts HTTPTransport and CommandRunning implementations for fixture testing. RefreshCoordinator accepts a clock and jitter generator for deterministic scheduling tests.

## Local Commands

Use full Xcode for the Swift Testing runtime. If Command Line Tools is the active developer directory, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
make build
make test
make app
open "build/LLM Meter.app"
```

For a faster development bundle:

```sh
CONFIGURATION=debug ./scripts/build-app.sh
```

The build script generates the application icon, assembles Info.plist and the executable, and verifies the bundle signature. Supply `SIGNING_IDENTITY` for a Developer ID signature. The default ad-hoc signature is for local development and does not constitute a notarized release.

The GitHub workflow runs tests and packages an arm64 bundle on a macOS runner. CI does not use personal accounts. Its downloadable app artifact is a development build, not a notarized release.

## Provider Sources

### Codex

Default source: `${CODEX_HOME}/auth.json`, or `~/.codex/auth.json` when CODEX_HOME is absent. Finder launches may not inherit shell environment variables, so choose a custom file explicitly when necessary.

A source must expose `tokens.access_token` and `tokens.account_id` for subscription authentication. API key authentication is rejected. The adapter reads `/backend-api/wham/usage` and maps only explicitly identified five-hour/seven-day windows to the panel columns. It rereads identity after fetching and discards results if the account changed. It never renews or writes external tokens. Keychain-only Codex authentication is not yet supported.

### Claude Code

Discover `claude` in `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, or `/bin`, or choose its executable explicitly.

Require version 2.1.285 or newer. Query `claude auth status --json` before and after usage to establish subscription account identity. Run `/usage` in print mode with tools, MCP configuration, hooks, and session persistence disabled. The command uses an isolated temporary working directory. Parse only recognized usage lines; reject missing allowance output and account changes.

Model-scoped weekly lines remain separate from the account-wide weekly value. A partial reading keeps unreported metrics with their original timestamps and marks them pending confirmation.

### Antigravity

The default source is the running Antigravity desktop client's local language server. Leave the source path blank or select **Use default source**, keep the client open and signed in, then refresh. Discover processes owned by the current user whose executable is inside `Antigravity.app/Contents`; prefer the standalone desktop client, then a stable PID order. Read the process's CSRF flag in memory and discover its numeric loopback-only listening ports with `lsof`. Query only `GetUserStatus` and `RetrieveUserQuotaSummary` over loopback HTTP, with redirects disabled. No TLS verification exception, browser cookies, OAuth login, refresh-token access, generation request, or client-storage modification is involved.

Verify the process/CSRF identity and signed-in account again after the read; discard restarted-client or switched-account responses. Missing quota summaries fall back to model quotas and mark the snapshot partial, preserving earlier group readings as unconfirmed. Raw status responses and CSRF values are not retained in the usage cache. Discovery commands use the bounded, cancellable subprocess runner and its private, automatically removed temporary output files.

Alternatively, choose an existing single-account OAuth JSON file in Settings. Accepted access-token shapes include:

```json
{
  "type": "antigravity",
  "access_token": "<current access token>",
  "project_id": "<project identifier>"
}
```

or:

```json
{
  "token": {
    "access_token": "<current access token>",
    "project_id": "<project identifier>"
  }
}
```

These are schema examples, not credentials to commit. The application stores only the source path, never the file contents. A refresh-token-only export is insufficient; no OAuth refresh request is made. The file's owner must keep its access token current.

The OAuth fallback verifies account identity with Google's userinfo endpoint. When project_id is absent, it queries loadCodeAssist with Antigravity metadata, without onboarding or modifying the account. It then queries fetchAvailableModels and retrieveUserQuotaSummary. These are internal client APIs and can change. Source changes during a refresh invalidate its result.

A reset timestamp does not establish a window duration. Quota summary buckets explicitly named 5h or weekly appear in separate rows for each reported group, such as Gemini Models and Claude/GPT. Model metrics retain their scope and appear in tooltips, the Services tab, and the menu bar metric picker; when no groups are available, the panel displays model quotas with unknown window duration. A missing remainingFraction stays unknown.

The local path was verified against the installed running client during development. The client must remain open; changes to its private RPC schema or process layout can require adapter updates. Automatic monitoring supports executable paths without whitespace and numeric loopback listeners; custom OAuth JSON is the fallback for unsupported client layouts.

### GitHub Copilot

Supports github.com accounts. Discover editor credentials in `$XDG_CONFIG_HOME/github-copilot/apps.json` or `hosts.json` (default `~/.config`), followed by `$COPILOT_HOME/config.json` (default `~/.copilot`). Parse CLI JSONC without altering quoted tokens. CLI tokens may be in the config or in the existing `copilot-cli` Keychain entry. Keychain queries use a noninteractive authentication context: unavailable access shows setup guidance rather than a repeated authorization prompt. An explicit single-account JSON containing `oauth_token`, optional `user`, and optional github.com `host` is also accepted. Multiple distinct editor accounts require an explicit single-account source; several tokens for the same account are tried in stable order after authentication rejection.

Read `/user` to establish stable GitHub account identity, then GET `/copilot_internal/user` with the existing token. Only github.com's fixed API origin receives credentials; redirects are disabled. Reread the source and reject changes. No OAuth login, token renewal/exchange, inference, or external sign-in modification is performed. The private quota endpoint can change and is not the aggregate organizational usage API.

The Monthly section preserves `quota_snapshots` metrics for premium interactions, chat, and completions. Interpret numeric or string entitlement/remaining amounts; otherwise use explicitly reported percentages. Token-based premium interactions are labeled AI Credits, while legacy units stay requests. Explicit Unlimited is distinct from missing values and zero entitlement. A premium pool reporting unavailable quota is not claimed to be unlimited. Prefer source reset timestamps, including per-quota Unix timestamps and UTC date-only fallbacks. Do not convert credits to money or monthly quotas into 5h/Weekly values. [GitHub's billing documentation](https://docs.github.com/en/copilot/concepts/billing-and-usage/individuals/billing) describes the monthly AI-credit cycle.

Original three-provider settings gain Copilot at the end while preserving existing order, visibility, account binding, and display preferences. Loading does not rewrite the file; later normal saves persist the upgraded configuration. Older metric caches default added amount/unit/unlimited fields safely.

Provider menu bar icons use bundled monochrome assets from LobeHub Icons, with their MIT license and source SVGs included. The application resource bundle is packaged under Contents/Resources; the SwiftPM executable uses its build resource bundle during development.

## Persistence and Refresh

Store `settings.json` and `usage-cache.json` in `~/Library/Application Support/LLM Meter/`. Files use 0600 permissions and atomic replacement. Credentials and raw responses are excluded. Snapshot changes are tracked as dirty, then written once when the refresh batch becomes idle; unchanged error/status events do not rewrite the cache. App shutdown flushes pending snapshot changes. On unreadable or unsupported storage, preserve the original file and prevent automatic replacement. To recover manually, quit the app, move the affected file aside, and relaunch.

The menu bar and panel share one snapshot store. The panel places reset countdowns beneath the simultaneous 5h/Weekly values and a single update-age label in the footer. That label uses the most recent successful read among visible enabled services; its tooltip lists each service’s individual update status. Tooltips retain exact local reset/reading times and details for all metrics. Countdown calculations use the source-reported absolute timestamp and never renew usage locally. Current adapters do not supply reset-credit counts. Cached accounts remain unconfirmed until a successful fetch. A menu bar selection binds a stable account ID; when the signed-in account changes, users must select a metric again to bind the new account.

The panel uses an accent-colored meter in its header, a used/remaining badge, rounded monospaced percentages, secondary countdowns, and fine service separators. Antigravity group names sit beneath their service heading. A horizontal footer provides Refresh, Settings, and Quit, with press feedback on the main actions. Native semantic colors adapt to appearance; text and VoiceOver descriptions preserve status meaning without relying on color.

Fresh percentages use green below 50% used, orange from 50% to below 80%, and red at 80% or more. Colors are based on consumed allowance, so the same quota remains red when displayed as a low remaining percentage. Stale, unknown, expired, reset-pending, and disabled readings use secondary gray. The used/remaining badge explains the thresholds in its tooltip.

Automatic intervals respect provider minimums. Manual refresh coalesces in-flight requests and respects manual minimums and rate-limit cooldowns. Transient failures retain successful readings. Stale readings use `·`; hard-expired or reset-pending metrics show `—`. Failed automatic refreshes back off, while a user can retry non-rate-limited failures after the manual minimum.

Sleep cancels in-flight work and suspends scheduling. Wake checks due sources once. Generation checks prevent cancelled or outdated source results from changing the current state. At most four initial providers can fetch concurrently.

## Verification

Tests cover parsing and missing values, overages, model scopes, partial updates, reset time zones/year boundaries, cache permissions and corrupt-file preservation, cooldowns, request coalescing, source changes, account identity, and subprocess time/output/cancellation limits.

Manual native checks should cover:

- Click-to-open, outside-click/Escape closure, and Settings closure while remaining in the menu bar.
- Used/remaining labels, selected metrics, visibility, ordering, and settings restoration.
- Light/dark appearance, Retina rendering, VoiceOver text, and narrow menu bar space.
- Login startup from a stable signed bundle, single instance, sleep/wake, and exit cleanup.

Development validation established successful live Codex, local Antigravity, and Copilot readings. Claude Code was installed but its current authentication did not expose a subscription account. Its live read remains unverified; validate `claude -p /usage` with a real subscription login and CLI version 2.1.285 or newer before claiming that integration is fully verified. Fixture tests cover its request and parsing paths.

The subprocess runner uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP` to assign an independent process group before execution. File actions provide null stdin, private output files, and an isolated working directory; other file descriptors are closed by default. Cancellation and timeout signal the group with TERM and then KILL, retaining the unreaped leader until escalation and reaping it with `waitpid`. Descendants that deliberately leave the process group are outside this cleanup guarantee. It currently inherits the environment for CLI compatibility; an explicit environment allowlist is a follow-up hardening task.

## Screenshots and GitHub Workflows

Run `make screenshots` to rebuild the light and dark previews in `docs/images/`. Use `--export-screenshot <path> --dark` for an individual dark preview. The exporter renders the actual SwiftUI panel with deterministic fictional quotas and an isolated temporary store. It does not read personal settings, start the refresh scheduler, or query usage sources. The menu bar sample uses the same provider icon and value as the app.

`ci.yml` runs strict formatting and core tests. `package.yml` builds the arm64 app, verifies architecture and its ad hoc signature, and uploads the ZIP plus SHA-256 checksum for 30 days. Both run on pull requests and main and allow manual dispatch; packaging also runs on `v*` tags. No credential secrets are required, and no release is published. Before public distribution, configure Developer ID signing and notarization, including stapling and Gatekeeper validation.

The minimum deployment target is macOS 13; execution on an actual macOS 13 machine and Developer ID signing/notarization remain release checks. Automatic refresh currently uses a timer; immediate network-recovery notifications are a follow-up improvement.
