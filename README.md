# usagebar

[![tests](https://github.com/bsnydr/usagebar/actions/workflows/tests.yml/badge.svg)](https://github.com/bsnydr/usagebar/actions/workflows/tests.yml)

A macOS menu-bar app that shows how much of your Claude (Pro or Max) and ChatGPT (Plus or Pro, via Codex)
subscription limits you have used and when each window resets. It reads the usage samples the Claude desktop
app already writes to disk, borrows the Claude Code CLI's sign-in read-only while one is valid, and reads the
Codex sign-in read-only for ChatGPT. It never refreshes or rewrites another app's token. One Swift file, no
dependencies, no Xcode project: it builds with the Command Line Tools and installs itself as a login item.

```
✱ 13%  ⬡ 0%        <- menu bar: weekly window for Claude (✱) and ChatGPT/Codex (⬡)
```

Click it for the full picture:

```
Claude · Max 20x
  5-hour   [██████░░░░]  61% · resets ≈ in 4h 5m
  Weekly   [█░░░░░░░░░]  13% · reset time n/a
  exact reset times need a signed-in `claude` CLI — see README
  from the Claude app · sampled 3 min ago
ChatGPT · Plus
  5-hour   [░░░░░░░░░░]   1% · resets in 4h 59m
  Weekly   [░░░░░░░░░░]   0% · resets Sat 13:53
  1 full-reset credit available
  live · updated just now
Refresh now            ⌘R
Open Claude usage page
Quit UsageBar
```

## The problem

Both subscriptions meter usage in rolling windows, 5-hour and weekly, and neither puts the number anywhere I
look during the day: Claude's lives on a settings page at claude.ai, ChatGPT's inside the Codex app. The
failure mode is hitting a limit mid-task with no warning. I wanted both figures in the menu bar, coloured by
how close they are to the ceiling, with a notification before I get there, and I wanted it without handing a
third-party tool my credentials or having it fight the official clients over their tokens.

## Quickstart

### Prerequisites

- macOS 14 or later, Apple silicon or Intel (`build.sh` builds for whatever `uname -m` reports).
- Xcode Command Line Tools (`xcode-select --install`). Nothing else: no Xcode project, no package manager.
- For the Claude figures: the Claude desktop app (percentages), and optionally a signed-in `claude` CLI for
  exact reset times (see [About the Claude sign-in](#about-the-claude-sign-in)).
- For the ChatGPT figures: Codex signed in with your ChatGPT account (it keeps `~/.codex/auth.json`).

### Install

```bash
git clone https://github.com/bsnydr/usagebar.git
cd usagebar
./install.sh      # build, copy to ~/Applications, start now and at every login
./uninstall.sh    # stop it and remove the login item + app
```

Re-running `install.sh` after editing `UsageBar.swift` rebuilds and restarts it. macOS shows a one-time
"added as a background item" notice; the item lives under System Settings › General › Login Items &
Extensions. Allow notifications when asked on first launch. Log: `~/Library/Logs/usagebar.log`.

### Publishing your changes (optional)

Off by default. In a clone you can push from, opt in once:

```bash
git config usagebar.autopush true
```

From then on a successful `./install.sh` finishes by running `./publish.sh`, which commits your edits to the
project's own files and pushes them to `main`. Pass a commit message as the first argument,
`./install.sh "Lower the warn threshold to 60"`, or run `./publish.sh "message"` yourself at any time. The
install reports `Install: ok` separately from the `Publish:` result (`pushed`, `up to date`, `disabled`,
`stopped: <reason>`, or `local commit kept, push failed`). A publishing failure does not undo the install.

- **Your own fork:** publishing only targets this project's GitHub address unless you say otherwise. Set your
  own with `git config usagebar.publishRemote <URL>`, written exactly as `git remote get-url origin` prints
  it, and `git config usagebar.publishBranch <branch>` if you don't use `main`.
- It runs `bash test.sh` first and only publishes the files listed in `ALLOWED_PATHS` at the top of
  `publish.sh`; add a new file to that list when you want it published.
- Configure `user.name` and `user.email` explicitly. The helper builds the verified commit in a temporary
  index; existing staged work makes it stop. Sparse or split indexes, skip-worktree and assume-unchanged
  entries also make it stop. Automatic publishing skips commit hooks and the pre-push hook. Reference
  transaction hooks and remote server hooks still apply. Use ordinary Git commands if you need the skipped hooks.
- If anything unexpected is in the way (other changes, something already staged, a remote that has moved
  ahead), it stops and says why without changing your files. It never fetches, merges, rebases or
  force-pushes, so if the remote moved, fetch it and take a look first. The destination branch must already
  exist. Unpublished merge commits require manual review and publication.
- If the push fails after a commit was prepared, that reviewed commit stays local for a later retry.
- A quick check refuses files that look like they contain a private key, an access token or a personal
  home-directory path. It is a safety net, not a guarantee.

### Expected output

`install.sh` ends with:

```
Built build/UsageBar.app
UsageBar is running and will start at login. Look for ✱ and ⬡ in the menu bar.
Install: ok
Publish: disabled
```

`Publish: disabled` is normal unless you opted in to [publishing](#publishing-your-changes-optional).

The same numbers without the UI, from the self-test:

```
$ build/UsageBar.app/Contents/MacOS/UsageBar --once
Claude · Max 20x  [Claude app, 6 min ago]
  5-hour            8%    reset time n/a
  Weekly            61%   reset time n/a
  note: exact reset times need a signed-in `claude` CLI — see README
ChatGPT · Plus  [API, just now]
  5-hour            0%    resets in 4h 59m
  Weekly            12%   resets Sat 13:53
  1 full-reset credit available
(Claude API user agent: claude-cli/2.1.291 (external, cli))
```

On a machine with nothing signed in it prints a "no data" line for Claude and a "not signed in" line for
ChatGPT and still exits 0; that is what CI runs.

## How it works

```
Claude desktop app   plan-usage-history.json (no credentials)             ─┐
Claude Code CLI      Keychain sign-in (read-only) → api.anthropic.com      ─┼─┐
Codex                ~/.codex/auth.json (read-only) → chatgpt.com          ─┘ │
                                                                              │
                 every 3 min · menu open · wake from sleep · ⌘R  ─────────────┤
                                                                              ▼
                                            fetch both, carry forward on failure
                                                             │
                     ┌───────────────────────────────────────┼────────────────────┐
                     ▼                                       ▼                    ▼
           menu-bar title (colour, "!")    menu rows (updated in place    notifications
                                           while the menu is open)        at 80% and 95%
                                                             │
                                                             ▼
                                            history.jsonl (fresh readings only)
```

1. **Claude, exact path.** If the `claude` CLI's sign-in in the Keychain is still valid, UsageBar calls the
   usage endpoint with it and shows the 5-hour, weekly and per-model weekly windows with real reset times.
   The sign-in is only read. Near expiry, UsageBar initializes the CLI protocol to let the CLI renew its own sign-in, without sending
   a model prompt (see [About the Claude sign-in](#about-the-claude-sign-in)).
2. **Claude, everyday path.** Otherwise it reads the last sample the Claude desktop app wrote (`fh` = 5-hour %,
   `sd` = 7-day %, `xu` = extra usage). The file carries no reset time, so the 5-hour reset is estimated from
   when usage last rose from 0, plus five hours, and marked ≈. The weekly reset is shown as n/a.
3. **ChatGPT.** It reads the Codex access token, checks the token's own expiry, and calls the usage endpoint:
   primary (5-hour) and secondary (weekly) windows with reset times, the "Reserve" bucket when the main one is
   exhausted, and any full-reset credits. Codex keeps that token fresh; if it has expired UsageBar asks you to
   open Codex once.
4. **A failed fetch never blanks a reading.** It keeps the previous numbers, marks them "last known", and
   shows the reason underneath.
5. **Colour.** The menu-bar figure is each provider's weekly window (its first window if it has no weekly one). Normal below 70%, orange from 70%, red
   from 90% with a `!`; the colour reflects whichever of the 5-hour or weekly window is highest. Grey means
   the data is over 30 minutes old (for example the Claude app is not running); the menu says how old.
6. **Claude reset availability.** With a valid CLI sign-in, an hourly read of the optional reset-grants
   response shows banked usage-limit resets and the next expiry. Expired grants are excluded. Missing or
   failed reads show availability as unknown. UsageBar only displays resets; use the Claude usage page to
   redeem one. The count may lag a redemption by up to an hour.
7. **Notifications.** One macOS notification when a window crosses 80% and another at 95%, re-armed after
   the window resets. The high-water marks are stored, so a restart does not repeat them.
8. **History.** Every poll appends one line to `~/Library/Application Support/UsageBar/history.jsonl`, e.g.

   ```json
   {"chatgpt":{"5-hour":1,"Weekly":0,"at":1788610990},"claude":{"5-hour":61,"Weekly":13,"at":1788610800},"t":1788611000}
   ```

   `t` is when the line was written, `at` is when that provider's numbers were produced. Readings older than
   30 minutes are left out rather than repeated.

## Where the numbers come from

| Provider | Source | Notes |
|---|---|---|
| Claude (always available) | `~/Library/Application Support/Claude/plan-usage-history.json` | The Claude desktop app writes usage samples while its own polling is active (`fh` = 5-hour %, `sd` = 7-day %, `xu` = extra usage). No credentials involved. It has no reset time, so UsageBar estimates the 5-hour reset from when usage last rose from 0 (marked ≈). |
| Claude (exact, when available) | Claude Code CLI sign-in (Keychain item `Claude Code-credentials`) → `GET api.anthropic.com/api/oauth/usage` | Exact 5-hour / weekly / per-model utilisation with real reset times. Read-only: used only while the CLI's own sign-in is valid. |
| ChatGPT | `~/.codex/auth.json` (Codex sign-in, read-only) → `GET chatgpt.com/backend-api/wham/usage` | The Codex limits that come with the ChatGPT plan: 5-hour and weekly windows with reset times, reset credits, and the "Reserve" bucket when the main one is exhausted. Codex keeps the token fresh; if it expires UsageBar says "open Codex once". |

Claude reset availability is read separately from `GET api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1`,
using the installed CLI's current User-Agent format. This optional response is checked at most hourly, including
failed checks, to avoid its stricter rate limit; ordinary percentage polling stays at three minutes. A failed
reset check never removes the usage bars. [OpenUsage's client implementation](https://github.com/robinebers/openusage/blob/main/Sources/OpenUsage/Providers/Claude/ClaudeUsageClient.swift)
documents this read shape; the grant response was also verified against a live account. See
[Anthropic's limit-reset explanation](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset) for the product behaviour.

UsageBar sends each credential only to the service it belongs to, never writes to Codex's auth file, never
writes to the Claude Code Keychain item, and never logs a token.

### About the Claude sign-in

The exact path (real reset times, per-model weekly windows) needs the `claude` command-line tool to be signed
in once:

```bash
claude auth login
```

That sign-in's access token lasts about 8 hours. Near expiry, UsageBar starts the real `claude` CLI in
streaming mode, sends only a protocol `initialize` control request, and closes its input. CLI initialization
renews the CLI's own sign-in; UsageBar then reads it again. No user prompt is sent, no model is requested,
and no conversation is saved. This was verified with Claude Code 2.1.291, including recovery from an expired
sign-in. UsageBar still never writes credentials itself.

Attempts are limited to once every 30 minutes and logged to `~/Library/Logs/usagebar.log`. The command runs
with a minimal environment so inherited API keys cannot change its authentication source. If initialization
fails or the CLI is signed out, UsageBar keeps the desktop fallback and shows the sign-in hint.

This replaces the old one-word Haiku nudge, which required a known active usage window. That created a
recovery deadlock when Claude's desktop samples stopped updating: the sign-in expired, but stale samples
could not prove an active window. The desktop app can pause its own polling when its menu has not been
opened recently, so merely leaving Claude running does not guarantee fresh samples. Initialization does
not send an inference request and therefore does not require that activity check.

**Tried and reverted: self-renewing it.** `Config.claudeSelfRefresh` exists to make UsageBar renew the sign-in
itself, an hour ahead of expiry — a plain OAuth renewal call, not a model request, so it would cost no usage —
and write the renewed pair back into the *same* Keychain item `claude` itself reads, never a separate copy
(a separate copy would race the CLI's own renewals, since Anthropic rotates the refresh token on every use;
one shared item can't race itself). The mechanism is sound on paper, but testing found the renewal call
(`POST grant_type=refresh_token` to `Config.claudeTokenURL`) gets a persistent `429 rate_limit_error` from
Anthropic when made as a bare HTTPS request — unchanged across 80+ minutes and several variations (different
timing, adding a `claude-code` User-Agent) — while the real `claude` binary's own internal refresh worked
fine in the same window. Never established whether that's a strict quota this testing burned through or a
structural block on non-CLI callers; either way, it's off (`claudeSelfRefresh = false`) until someone confirms
which. If you want to chase it further: capturing what the actual `claude` binary sends on its own refresh
(network trace) would settle it, but be aware that repeated calls against Anthropic's auth endpoint is what
triggered the extended rate-limiting in the first place.

## Key technical decisions and tradeoffs

- **Never refresh or rewrite another app's token.** UsageBar reads the Claude Code CLI's Keychain item and
  Codex's `auth.json`, sends each token only to its own service, and never writes either back. Tradeoff: exact
  Claude numbers depend on the CLI sign-in and its protocol initialization behaviour. UsageBar initializes
  the CLI near expiry without sending a model prompt; if that fails, the desktop fallback can be stale. Tried lifting this for Claude specifically
  (renew in place, write back into the CLI's own shared item — see "About the Claude sign-in"); the renewal
  call itself couldn't be gotten working reliably in testing, so it's reverted and off by default.
- **The Claude desktop app's file as the credential-free primary source.** `plan-usage-history.json` is
  written while the desktop app's polling is active and carries 5-hour and 7-day percentages. No credentials, no
  network. It has no reset time, so UsageBar estimates the 5-hour reset from the latest 0 → >0 transition plus
  five hours and marks it ≈. Tradeoff: desktop polling can pause unless its own menu was opened recently; the figure is only as fresh
  as the last sample (it turns grey after 30 minutes without one), the weekly reset time is unknown, and the estimate gives up if the first
  message after a reset went unsampled.
- **One Swift file, no dependencies, no Xcode project.** `build.sh` runs `swiftc` from the Command Line Tools
  against AppKit and UserNotifications, copies `Info.plist` in and ad-hoc signs. The whole app reads in one
  sitting and rebuilds in seconds. Tradeoff: no SwiftPM target; `bash test.sh` compiles the declarations with isolated regression checks.
  There is no signing identity, so macOS shows its usual notices for an unsigned background
  item.
- **In-place menu updates.** Replacing item views on an open `NSMenu` flickers on macOS 26. The menu is
  rebuilt only in `menuWillOpen`, before it is on screen, and when closed; a refresh that lands while it is
  open updates the existing rows in place if the row structure is unchanged. Tradeoff: a structural change (a
  new per-model window appearing) while the menu is open waits for the next open, and there are two update
  paths to keep in sync.
- **3-minute polling with refresh on open, on wake and on demand.** A fixed timer, a refresh when the menu
  opens if the data is over a minute old, a refresh 15 seconds after wake, and ⌘R. A 429 from the Claude API
  backs off for at least 10 minutes. Neither provider pushes. Tradeoff: up to three minutes of lag, and a
  fetch every three minutes against endpoints that were not designed for a third-party poller.
- **A failed refresh never blanks a reading.** `carryForward` keeps the previous numbers, flags them "last
  known" and shows the error underneath. Tradeoff: stale numbers can pass for current at a glance; the grey
  colour and the age line are the only signals.
- **Threshold notifications persisted in `UserDefaults`.** One notification at 80% and one at 95% per window,
  re-armed when the window resets, with the high-water marks stored so a restart or reinstall does not fire
  them again. Tradeoff: the store is keyed by window label, not reset cycle, so a window that resets and
  climbs past 80% between two polls is missed.
- **`history.jsonl` only logs fresh readings.** A provider appears in a line only when its data is under 30
  minutes old and not carried forward, so a desktop-app sample that has not changed for hours never looks
  like new usage. Tradeoff: gaps whenever the Claude app is closed, and the log is raw material for a chart
  that does not exist yet.

### What I'd improve

- Figure out why `Config.claudeSelfRefresh`'s renewal call gets a persistent 429 as a bare HTTPS request —
  network-trace the real `claude` binary's own refresh to see what it sends differently — or delete the
  feature if it turns out to be structurally blocked for non-CLI callers.
- Split the file so the pure functions (`estimateFiveHourReset`, `jwtExpiry`, `resetText`, `Codex.window`)
  can be unit-tested.
- A universal binary via `lipo` instead of building for the host architecture.
- A chart over `history.jsonl`: when in the day and week the limits actually bite.
- A proper icon instead of ✱ and ⬡.
- A weekly reset time on the desktop-app path.

## Limitations / scope

- macOS 14 or later, menu bar only. No Windows, no Linux, no iOS.
- Two providers, each through exactly one route: Claude via the desktop app's samples or the `claude` CLI
  sign-in, ChatGPT only via a Codex sign-in. No API-key accounts, no Team or Enterprise plans.
- It cannot show the ChatGPT chat app's own caps (images per day, uploads). OpenAI exposes no read-only
  endpoint for those; the Codex windows are the account-level limits that are reachable programmatically.
- It depends on private endpoints and file formats: `api.anthropic.com/api/oauth/usage`,
  `chatgpt.com/backend-api/wham/usage`, `plan-usage-history.json`, and the shape of the Claude Code Keychain
  item. Any of them can change without notice, and the app will start showing an error line instead of
  numbers.
- Exact Claude figures need a signed-in `claude` CLI. UsageBar asks the CLI to renew its sign-in through
  protocol initialization; this depends on CLI behaviour verified with version 2.1.291. Desktop samples are
  a fallback and may stop updating even while the desktop app is running.
- Single user, single machine. The history log and the notification high-water marks live in this user's
  Library folder; nothing syncs.
- Ad-hoc signed. Not notarised, not in the App Store, and I have only run it on Apple silicon; the Intel
  build path exists but is untested.

## Configuration

All knobs are at the top of `UsageBar.swift` in `Config`:

| Knob | Default | What it does |
|---|---|---|
| `pollInterval` | 3 min | background refresh cadence |
| `staleAfter` | 60 s | refresh when the menu opens if the data is older than this |
| `staleData` | 30 min | grey the menu-bar figure, and skip history logging, when data is older than this |
| `warnAt` / `alertAt` | 70 / 90 | orange / red (plus `!`) thresholds |
| `notifyAt` | 80, 95 | notification thresholds, once per window cycle |
| `claudeGlyph` / `gptGlyph` | ✱ / ⬡ | the two menu-bar glyphs |
| `claudeSelfRefresh` | false | let UsageBar renew the Claude sign-in itself (see "About the Claude sign-in" — the renewal call isn't confirmed working yet) |
| `claudeUserAgentFallback` | `claude-cli/2.1.291 (external, cli)` | User-Agent for the Claude usage endpoint when no `claude` binary is around to ask |
| `claudeAppHistory`, `codexAuthPath`, `logDir` | see file | where the inputs and the history log live |

Edit, then run `./install.sh`.

## Troubleshooting

- The ✱ ⬡ item never appears: macOS 26 may have it switched off under System Settings › Menu Bar › Allow in
  the Menu Bar.
- Numbers look wrong or stale: `tail ~/Library/Logs/usagebar.log`, then run the self-test
  (`~/Applications/UsageBar.app/Contents/MacOS/UsageBar --once` for the installed copy) to see exactly what
  each source returns.
- "Claude: no data": open the Claude desktop app once so it writes a sample, or sign the CLI in.
- `Publish: stopped: ...` after an install: the app is installed and running regardless. The lines above the
  message name the file or reason; fix that and run `./publish.sh` again.

## Development checks

Run `bash test.sh` for the isolated Swift regression checks and `bash tests/publish.sh` for publishing
behavior against disposable local Git repositories. The latter uses Python 3's standard library as a
development dependency; the app and publishing helper do not need Python. These tests do not contact
GitHub, read real sign-ins, or install the app.

## Project layout

```
test.sh                     isolated Claude renewal regression checks (no credentials or network)
tests/ClaudeRenewal.swift    expired/near-expiry sign-in recovery and fallback checks
tests/publish.sh             checks publish.sh against throwaway local repositories (no network, no GitHub)
UsageBar.swift               the whole app: Config, Claude and Codex fetchers, menu, notifications, --once self-test
Info.plist                   bundle metadata; LSUIElement (no Dock icon), LSMinimumSystemVersion 14.0
build.sh                     swiftc → build/UsageBar.app; Command Line Tools only, targets the host architecture
install.sh                   build, copy to ~/Applications, write the LaunchAgent, start it, then run publish.sh (safe to re-run)
publish.sh                   opt-in commit + push of the project's own files (the ALLOWED_PATHS list at its top)
uninstall.sh                 stop it, remove the LaunchAgent and the app
com.bsnydr.usagebar.plist    LaunchAgent template; install.sh replaces __HOME__ and writes it to ~/Library/LaunchAgents
.gitignore                   keeps build output, logs and credential-looking files out of commits
.github/workflows/tests.yml  build + regression checks + publish.sh checks + --once smoke test on a macOS runner
```

The bundle id and launchd label are `com.bsnydr.usagebar`. To use your own, change it in `Info.plist`, the
plist filename and its `Label` and `AssociatedBundleIdentifiers` keys, `install.sh` and `uninstall.sh`
together.

## License

MIT — see [`LICENSE`](LICENSE).
