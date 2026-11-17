# Claude Usage Bar

macOS menu bar app that shows Claude Code plan usage (5-hour, weekly, per-model weekly) for several Claude accounts at once.

<img src="docs/screenshot.png" width="380" alt="Panel with five accounts">

## Install

```sh
make install   # builds dist/ClaudeUsageBar.app, copies it to /Applications, launches it
```

Requires macOS 14+ and a Swift 6 toolchain.

## Accounts

Click **添加账号**: the browser opens Claude's OAuth page; pick the organization and approve. Each account is keyed by organization, so several orgs under one email work. The app requests only `user:profile` (usage and profile reads, no inference), keeps its own refresh token in the login keychain (`com.nimrc.claude-usage-bar`), and never touches Claude Code's credentials.

Usage refreshes every 5 minutes and when the panel opens.

## CLI

```sh
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --status
```

Prints every account's limits. Read-only: it uses the stored access tokens and never refreshes them, so it cannot invalidate the running app's refresh token.

## Development

```sh
make build && make test
```
