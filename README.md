<p align="center">
  <img src="docs/icon.png" alt="Uso" width="128">
</p>

# Uso

Menu bar app for macOS. It shows what is left on Grok, Grok Bot, Cursor, Codex, Claude, Muse Code, and OpenCode.

The menu bar cycles through the accounts, about 3 seconds each. Claude shows the 5-hour window, then the week. Cursor shows Auto, then included dollars. Click the item to open the panel. Click anywhere else, or press Escape, to hide it. Open a row for the full breakdown.

The panel opens with a short spring animation, staggered rows, a moving edge highlight, and animated meters. macOS Reduce Motion disables these effects. Escape returns from a detail to the list, then closes the panel; Command-R refreshes the usage.

<p align="center">
  <img src="docs/panel.png" alt="Usage menu bar panel" width="328">
</p>

Requires macOS 14 or later on Apple silicon.

## Install

Download the latest zip from the [releases page](https://github.com/bujosa/uso/releases/latest).

1. Unzip the file. You get `Uso.app`.
2. Move `Uso.app` into Applications.
3. Open it. If macOS says the app cannot be checked, right-click `Uso.app`, choose Open, then Open again.
4. Look in the menu bar. The label cycles through each account.

The app does not show a Dock icon. Quit it from the panel.

Sign in with the Claude Code CLI. Uso rereads that live session for each refresh and does not log in, refresh the token, write the keychain, or save a copy of the credentials. A failed refresh keeps the last percentages on the row, labeled with the last successful reading time. Those old readings leave the menu bar rotation until the next successful refresh. A rejected or missing session clears the old account's numbers.

For Grok Bot, sign in to Cursor with the same account you use in Grok Bot. Its weekly allowance is separate from the Grok Build credits. Uso uses Cursor's local session; it does not decrypt Grok Bot's credential storage.

For Muse Code, run `muse login`. Uso reads the CLI-owned account session without refreshing it, rewriting it, or saving a copy. If macOS requires permission, choose Allow access in Uso. API-key accounts and incomplete billing are labeled separately from subscriptions.

## From source

```sh
./scripts/install.sh
```

That builds a release binary, installs `~/Applications/Uso.app`, and opens it. `./scripts/package.sh` only writes `dist/Uso-1.1.0-macOS.zip`.

Run `swift test` for quota parsing, session rotation, failed refresh, rate-limit, plan metadata, and preference persistence regression tests. Run `swift build -c release` to check the release build.

## What each row shows

- **Grok.** Weekly credits, plus Build, Imagine, Chat, and Voice when the account returns them.
- **Grok Bot.** The bot account's weekly allowance, or trial usage when applicable. Managed pooled enterprise allowances are labeled instead of shown as a personal quota.
- **Cursor.** Auto, then included dollars, on the row. API usage and the token mix are inside the row. Auto is the pool for the other models.
- **Codex.** The weekly window is on the row. A shorter window, when the account has one, sits above it.
- **Claude.** Session and week are both on the row. A model week such as Fable, and the mix across Claude Code and the rest, are inside the row.
- **Muse Code.** The reported plan, current window, and weekly quota when Meta includes them. A subscription without a returned quota stays connected and shows Quota unavailable. Billing setup and pay-as-you-go accounts have no invented percentage bars.
- **Muse app.** A separate entry detects the standard app installation and opens Muse to view its account and usage. **In-app quota detection is not available in this release.** Its display choice is independent of Muse Code.
- **OpenCode.** Local tokens for today, the last 7 days, and all time. This is sessions on this Mac, not a plan quota. An OpenCode Go key adds the official quota.

Bars fill as usage goes up. Red means 90% or more used. Orange means 75% or more. The number on the row is what is left.

The panel refreshes when you open it, and again every 3 minutes. The refresh button forces a new read. If Claude returns HTTP 429, Uso waits for `Retry-After` (or 3 minutes when no valid delay is provided), including when the refresh button is pressed.

Muse Code account requests are limited to one per credential every 5 minutes, including manual refresh. Cached readings keep their original timestamp, passed reset windows are withheld, and HTTP 429 honors a longer Retry-After delay. The endpoint returns subscription data without a model prompt; its other fields, including the inference key and account identity, are discarded.

## Settings

Click the gear in the panel, or press Command-comma, to open Settings. Accounts & plans lists every supported source, its detected plan, and its connection state. Free plans and local OpenCode activity are labeled separately. Claude Max shows the 5× or 20× tier when the session reports it; Grok Bot also shows the Cursor tier returned by its account.

Each source has independent Panel and Menu bar switches. Choices are saved on this Mac and restored when Uso starts again. Hidden sources still appear in Settings, so you can show them again. Show detected only uses the last detected sources; Check now reruns detection. Manage account opens the provider's account website.

General has open-at-login and opening-animation controls, plus Show all sources to restore visibility. macOS Reduce Motion takes priority over the animation switch. Open at login uses the macOS login item for this app.

## Where the numbers come from

Uso reads the session each tool already saved on this Mac. It does not ask you to paste an API key.

| Service | Local session | Usage endpoint |
| --- | --- | --- |
| Grok | `~/.grok/auth.json` | Grok CLI billing |
| Grok Bot | Cursor's local database, same account as Grok Bot | Cursor dashboard `GetSandUsageStatus` |
| Cursor | Cursor's local database | Cursor dashboard |
| Codex | `~/.codex/auth.json` | Codex usage |
| Claude | Login keychain item `Claude Code-credentials` | Claude OAuth usage |
| Muse Code | `~/.config/muse/auth.json` and Keychain `ai.meta.dev.credentials` / `meta` | Meta `POST /muse-code/key` |
| Muse app | Standard installation or macOS app registration | Opens Muse; no quota collection yet |
| OpenCode | `opencode.db` on this Mac | OpenCode Go, only if that key is present |

Tokens stay in memory for the request. Uso does not write them to a log or to its own database.

These usage endpoints are internal APIs and can change. Grok Bot's allowance is metered on the Cursor account even when a linked SuperGrok plan funds it; see [plans and billing](https://cursor.com/help/grok-bot/plans). Claude accepts both the newer `limits` array and the older per-window fields, including model limits. Malformed quota values produce a refresh error rather than an assumed 100% remaining. Muse Code may omit quota data even for a verified subscription; Uso keeps the reported plan and explicitly marks the quota unavailable. `MUSE_AUTH_PATH` and `XDG_CONFIG_HOME` are honored for its CLI metadata, and an exported `META_API_KEY` selects pay-as-you-go instead of the account login.

## License

MIT. See [LICENSE](LICENSE).
