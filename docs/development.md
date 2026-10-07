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

Choose an existing single-account OAuth JSON file in Settings. Accepted access-token shapes include:

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

The adapter verifies account identity with Google's userinfo endpoint. When project_id is absent, it queries loadCodeAssist without onboarding or modifying the account. It then queries fetchAvailableModels and normalizes model quota fractions. These are internal client APIs and can change. Source changes during a refresh invalidate its result.

A reset timestamp does not establish a window duration. Model metrics retain their scope and appear in tooltips, the Services tab, and the menu bar metric picker. The compact account-level 5h/Weekly columns remain `—` when the response supplies only model quotas. A missing remainingFraction stays unknown.

Current limitation: automatic Antigravity desktop sign-in discovery and native CLI integration are not implemented. A configured current-token JSON source is required for a live read.

## Persistence and Refresh

Store `settings.json` and `usage-cache.json` in `~/Library/Application Support/LLM Meter/`. Files use 0600 permissions and atomic replacement. Credentials and raw responses are excluded. On unreadable or unsupported storage, preserve the original file and prevent automatic replacement. To recover manually, quit the app, move the affected file aside, and relaunch.

The menu bar and panel share one snapshot store. Cached accounts remain unconfirmed until a successful fetch. A menu bar selection binds a stable account ID; when the signed-in account changes, users must select a metric again to bind the new account.

Automatic intervals respect provider minimums. Manual refresh coalesces in-flight requests and respects manual minimums and rate-limit cooldowns. Transient failures retain successful readings. Stale readings use `·`; hard-expired or reset-pending metrics show `—`. Failed automatic refreshes back off, while a user can retry non-rate-limited failures after the manual minimum.

Sleep cancels in-flight work and suspends scheduling. Wake checks due sources once. Generation checks prevent cancelled or outdated source results from changing the current state. At most three initial providers can fetch concurrently.

## Verification

Tests cover parsing and missing values, overages, model scopes, partial updates, reset time zones/year boundaries, cache permissions and corrupt-file preservation, cooldowns, request coalescing, source changes, account identity, and subprocess time/output/cancellation limits.

Manual native checks should cover:

- Click-to-open, outside-click/Escape closure, and Settings closure while remaining in the menu bar.
- Used/remaining labels, selected metrics, visibility, ordering, and settings restoration.
- Light/dark appearance, Retina rendering, VoiceOver text, and narrow menu bar space.
- Login startup from a stable signed bundle, single instance, sleep/wake, and exit cleanup.

Development validation established a successful live Codex reading. Claude Code was installed but its current authentication did not expose a subscription account, and no Antigravity OAuth JSON was configured; live reads for those sources remain unverified. Fixture tests validate their implemented request and parsing paths.

The minimum deployment target is macOS 13; execution on an actual macOS 13 machine and Developer ID signing/notarization remain release checks. Automatic refresh currently uses a timer; immediate network-recovery notifications are a follow-up improvement.
