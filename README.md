# Claude Usage Bar

macOS menu bar app showing Claude API usage (session + weekly) in real time.

## Features

- **Dual progress bars** in menu bar — top = session (5h), bottom = weekly (7d)
- **Countdown timer** — time until session reset
- **Sparkline trend** — 6h usage history chart in dropdown (session blue / weekly orange)
- **Auto-reconnect** — NWPathMonitor detects network changes, refreshes on reconnect
- **Exponential backoff** — retries on failure (5s → 15s → 30s → 60s → 120s)
- **Crash recovery** — LaunchAgent auto-restarts on crash
- **Stale data display** — shows last known data during transient errors
- **Structured logging** — `~/Library/Logs/ClaudeUsageBar.log` (500KB rotating)

## Build & Install

```bash
./build.sh
cp -r build/ClaudeUsageBar.app /Applications/
```

## Auto-start (LaunchAgent)

```bash
cp com.tensor.claude-usage-bar.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.tensor.claude-usage-bar.plist
```

Unload: `launchctl unload ~/Library/LaunchAgents/com.tensor.claude-usage-bar.plist`

## Requirements

- macOS 13+
- Claude Code logged in (credentials in Keychain)

## Architecture

Single-file Swift app (`main.swift`), compiled with `swiftc -O -framework Cocoa`.

| Component | Detail |
|-----------|--------|
| Network | async/await URLSession, NWPathMonitor |
| Credentials | Keychain read via `/usr/bin/security`, 5min cache |
| UI | NSStatusItem, differential NSMenu update |
| Polling | 60s timer + watchdog (120s) |
| Retry | Exponential backoff, skip non-transient errors (401, no token) |
| Logging | Rotating file log with INFO/WARN/ERR levels |

## Debugging

```bash
tail -f ~/Library/Logs/ClaudeUsageBar.log
```
