# CodexStatusBar

`CodexStatusBar` is a native macOS menu bar app for checking Codex usage without opening session files or digging through logs.

The app reads the latest usage snapshots that Codex writes locally under `~/.codex/sessions` and shows the current usage windows directly in the menu bar as:

`primary - weekly`

Examples:

- `38 - 12`
- `4 - 1`

The first number is the current primary rate-limit window usage percentage.
The second number is the current secondary or weekly usage percentage when Codex exposes it.

## Features

- Native SwiftUI macOS menu bar app
- Local-only usage reading from `~/.codex/sessions`
- Compact color-coded menu bar display
- Dropdown cards for:
  - primary usage window
  - weekly or secondary usage window
  - reset timing
  - current plan label
- Automatic refresh on launch
- Background polling every 4 minutes for up to 60 minutes after activation
- Manual `Reload`, `Disable`, and `Check for Updates` actions
- GitHub-release-based updater for installed `.app` bundles

## How It Works

`CodexStatusBar` scans the newest session files in:

`~/.codex/sessions`

It looks for the most recent `token_count` event containing `rate_limits` data, then extracts:

- `rate_limits.primary`
- `rate_limits.secondary`
- `plan_type`

Those values drive the menu bar text and the dropdown breakdown cards.

## Requirements

- macOS 13 or newer
- Xcode or the Swift toolchain
- Codex installed locally
- At least one completed or active Codex session so `~/.codex/sessions` exists

## Run

From the project root:

```bash
swift run CodexStatusBar
```

## Build

Build the executable:

```bash
swift build
```

Run tests:

```bash
swift test
```

Build the app bundle:

```bash
APP_VERSION=0.2.0 ./scripts/build-app.sh
```

This creates:

`dist/CodexStatusBar.app`

Create the DMG:

```bash
VERSION=v0.2.0 ./scripts/create-dmg.sh
```

This creates:

`dist/CodexStatusBar-v0.2.0.dmg`

## Install

If you already built the app bundle:

```bash
open dist/CodexStatusBar.app
```

Or drag `CodexStatusBar.app` into `/Applications` after building or downloading a release DMG.

## Menu Bar Format

The menu bar uses:

`X - Y`

Where:

- `X` = primary window used percentage
- `Y` = secondary or weekly window used percentage

The `%` symbol is intentionally omitted to keep the status item compact.

## Dropdown Details

The dropdown includes:

- plan label from the latest usage snapshot
- one card per available usage window
- percent used
- percent remaining
- reset timing when available
- last refresh time
- app version
- update or parser status messages when relevant

Footer actions:

- `Reload` refreshes usage immediately
- `Check for Updates` checks the latest GitHub release
- `Disable` stops background polling until the menu is opened again
- `Quit` exits the app

## Project Structure

- [CodexUsageProvider.swift](/Users/azwandi/Development/codex-status-bar/Sources/CodexStatusBar/CodexUsageProvider.swift)
  Reads and parses Codex session usage snapshots.
- [UsageStore.swift](/Users/azwandi/Development/codex-status-bar/Sources/CodexStatusBar/UsageStore.swift)
  Manages refresh state, display values, and update checks.
- [MenuContentView.swift](/Users/azwandi/Development/codex-status-bar/Sources/CodexStatusBar/MenuContentView.swift)
  Renders the dropdown UI.
- [AppDelegate.swift](/Users/azwandi/Development/codex-status-bar/Sources/CodexStatusBar/AppDelegate.swift)
  Owns the status item and popover lifecycle.
- [AppUpdater.swift](/Users/azwandi/Development/codex-status-bar/Sources/CodexStatusBar/AppUpdater.swift)
  Checks GitHub releases and installs newer app bundles when possible.

## Known Limitations

- The app is only as accurate as the latest Codex session snapshot on disk.
- If no recent `token_count` event has been written yet, the app cannot show usage.
- If Codex changes its local JSONL schema, the parser may need to be updated.
- The updater expects GitHub release assets and works best when the app is launched from an installed `.app` bundle.

## Design Choices

- No browser automation
- No scraping from web pages
- No separate billing API integration
- Local Codex session data is the source of truth

## Release Notes

To publish a release manually:

1. Build the app bundle.
2. Build the DMG.
3. Create a GitHub release and attach `dist/CodexStatusBar-vX.Y.Z.dmg`.
