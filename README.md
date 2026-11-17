# Claude Usage Bar

macOS menu bar app that shows plan usage for several Claude Code, Codex, Kimi Code, Grok and sub2api accounts at once: 5-hour, weekly, per-model and billing-period limits with reset countdowns.

<img src="docs/screenshot.png" width="380" alt="Panel with six accounts, names hidden">

## Install

```sh
make install   # builds dist/ClaudeUsageBar.app, copies it to /Applications, launches it
```

Requires macOS 14+ and a Swift 6 toolchain.

## Accounts

**添加账号** offers one entry per provider:

| Provider | How it signs in | Usage source |
| --- | --- | --- |
| Claude | Browser OAuth, scope `user:profile` only (no inference) | `api.anthropic.com/api/oauth/usage` |
| Codex | Browser OAuth with the Codex CLI client; redirect fixed to `127.0.0.1:1455` (fallback `1457`) | `chatgpt.com/backend-api/wham/usage` |
| Kimi Code | Paste a Kimi Code API key (`sk-kimi-…`) | `api.kimi.com/coding/v1/usages` |
| Grok | Reads the grok CLI login (`~/.grok/auth.json`, run `grok login` first) on every poll, read-only | `cli-chat-proxy.grok.com/v1/billing` |
| sub2api | Deployment URL (HTTPS, or HTTP on loopback) plus a group API key | `<base>/v1/usage` |

OAuth accounts are keyed by Claude organization or ChatGPT account, so several under one email work. API keys are checked against the usage endpoint before they are saved.

Refresh tokens and API keys live in the login keychain (`com.nimrc.claude-usage-bar`). The app never writes the Claude Code, Codex or grok CLI credentials; Grok's token is renewed by the grok CLI, so an unused CLI eventually shows as expired. Usage refreshes every 5 minutes and when the panel opens.

The eye switch blurs account names for screenshots. Drag a card onto another to reorder.

## CLI

```sh
/Applications/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --status
```

Prints every account's limits. Read-only: it uses the stored access tokens and never refreshes them, so it cannot invalidate the running app's refresh tokens.

## Development

```sh
make build && make test
```

Provider logos in `Resources/Logos`: Claude and OpenAI from [simple-icons](https://simpleicons.org) (CC0), Kimi and Grok from [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT).
