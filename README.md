# usagebar

[![tests](https://github.com/bsnydr/usagebar/actions/workflows/tests.yml/badge.svg)](https://github.com/bsnydr/usagebar/actions/workflows/tests.yml)

A macOS menu-bar app that shows how much of your Claude (Pro or Max) and ChatGPT (Plus or Pro, via Codex)
subscription limits you have used and when each window resets. It reads the usage samples the Claude desktop
app already writes to disk, borrows the Claude Code CLI's sign-in read-only while one is valid, and reads the
Codex sign-in read-only for ChatGPT. It never refreshes or rewrites another app's token. One Swift file, no
dependencies, no Xcode project: it builds with the Command Line Tools and installs itself as a login item.

```
✱ 61%  ⬡ 1%        <- menu bar: 5-hour window for Claude (✱) and ChatGPT/Codex (⬡)
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

If this is your own fork and you want it kept in sync, opt in once with `git config usagebar.autopush true`;
from then on every successful reinstall also commits whatever changed and pushes it, and a message can be
passed as the first argument: `./install.sh "Lower the warn threshold to 60"`. Nothing that failed to build
is ever pushed, because the sync runs last.

### Expected output

`install.sh` ends with:

```
Built build/UsageBar.app
UsageBar is running and will start at login. Look for ✱ and ⬡ in the menu bar.
```

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
(Claude API user agent: claude-code/2.1.220)
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
   The sign-in is only read; if it has expired UsageBar says so and moves on.
2. **Claude, everyday path.** Otherwise it reads the last sample the Claude desktop app wrote (`fh` = 5-hour %,
   `sd` = 7-day %, `xu` = extra usage). The file carries no reset time, so the 5-hour reset is estimated from
   when usage last rose from 0, plus five hours, and marked ≈. The weekly reset is shown as n/a.
3. **ChatGPT.** It reads the Codex access token, checks the token's own expiry, and calls the usage endpoint:
   primary (5-hour) and secondary (weekly) windows with reset times, the "Reserve" bucket when the main one is
   exhausted, and any full-reset credits. Codex keeps that token fresh; if it has expired UsageBar asks you to
   open Codex once.
4. **A failed fetch never blanks a reading.** It keeps the previous numbers, marks them "last known", and
   shows the reason underneath.
5. **Colour.** The menu-bar figure is each provider's 5-hour window. Normal below 70%, orange from 70%, red
   from 90% with a `!`; the colour reflects whichever of the 5-hour or weekly window is highest. Grey means
   the data is over 30 minutes old (for example the Claude app is not running); the menu says how old.
6. **Notifications.** One macOS notification when a window crosses 80% and another at 95%, re-armed after
   the window resets. The high-water marks are stored, so a restart does not repeat them.
7. **History.** Every poll appends one line to `~/Library/Application Support/UsageBar/history.jsonl`, e.g.

   ```json
   {"chatgpt":{"5-hour":1,"Weekly":0,"at":1788610990},"claude":{"5-hour":61,"Weekly":13,"at":1788610800},"t":1788611000}
   ```

   `t` is when the line was written, `at` is when that provider's numbers were produced. Readings older than
   30 minutes are left out rather than repeated.

## Where the numbers come from

| Provider | Source | Notes |
|---|---|---|
| Claude (always available) | `~/Library/Application Support/Claude/plan-usage-history.json` | The Claude desktop app writes a usage sample every few minutes while it runs (`fh` = 5-hour %, `sd` = 7-day %, `xu` = extra usage). No credentials involved. It has no reset time, so UsageBar estimates the 5-hour reset from when usage last rose from 0 (marked ≈). |
| Claude (exact, when available) | Claude Code CLI sign-in (Keychain item `Claude Code-credentials`) → `GET api.anthropic.com/api/oauth/usage` | Exact 5-hour / weekly / per-model utilisation with real reset times. Read-only: used only while the CLI's own sign-in is valid. |
| ChatGPT | `~/.codex/auth.json` (Codex sign-in, read-only) → `GET chatgpt.com/backend-api/wham/usage` | The Codex limits that come with the ChatGPT plan: 5-hour and weekly windows with reset times, reset credits, and the "Reserve" bucket when the main one is exhausted. Codex keeps the token fresh; if it expires UsageBar says "open Codex once". |

UsageBar sends each credential only to the service it belongs to, never writes to Codex's auth file, never
writes to the Claude Code Keychain item, and never logs a token.

### About the Claude sign-in

Day to day the Claude figures come from the desktop app's samples, which is fine for percentages. The exact
path (real reset times, per-model weekly windows) needs the `claude` command-line tool to be signed in:

```bash
claude auth login
```

Caveat: that sign-in only stays valid for about 8 hours unless something refreshes it, and only Claude Code
itself refreshes it (the desktop app uses a separate sign-in). So unless you use `claude` in the Terminal
regularly, UsageBar will fall back to the desktop-app samples most of the time. There is a switch in
`UsageBar.swift` (`claudeSelfRefresh`) that lets UsageBar refresh the sign-in itself and keep its own copy in
the Keychain; it is **off** because Anthropic rotates refresh tokens, so the first refresh would sign the
`claude` command-line tool out until you log it in again. Turn it on only if you're happy with that trade.

## Key technical decisions and tradeoffs

- **Never refresh or rewrite another app's token.** UsageBar reads the Claude Code CLI's Keychain item and
  Codex's `auth.json`, sends each token only to its own service, and never writes either back. Anthropic
  rotates refresh tokens on every refresh, so a third party refreshing the CLI's token would invalidate the
  CLI's copy and sign it out. `Config.claudeSelfRefresh` exists as an opt-in that keeps a refreshed pair in
  UsageBar's own Keychain item; it is off by default and I have not tested it. Tradeoff: exact Claude numbers
  are only available for the roughly 8 hours after a `claude` sign-in, so most of the time the Claude figures
  come from the desktop app with an estimated reset.
- **The Claude desktop app's file as the credential-free primary source.** `plan-usage-history.json` is
  written every few minutes while the app runs and carries 5-hour and 7-day percentages. No credentials, no
  network. It has no reset time, so UsageBar estimates the 5-hour reset from the latest 0 → >0 transition plus
  five hours and marks it ≈. Tradeoff: the figure is only as fresh as the app's last sample (it turns grey
  after 30 minutes without one), the weekly reset time is unknown, and the estimate gives up if the first
  message after a reset went unsampled.
- **One Swift file, no dependencies, no Xcode project.** `build.sh` runs `swiftc` from the Command Line Tools
  against AppKit and UserNotifications, copies `Info.plist` in and ad-hoc signs. The whole app reads in one
  sitting and rebuilds in seconds. Tradeoff: no SwiftPM target, no unit tests (the file is top-level code and
  cannot be imported), and no signing identity, so macOS shows its usual notices for an unsigned background
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

- Test the self-refresh path properly or delete it.
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
- Exact Claude figures need a `claude` CLI sign-in that only the CLI keeps fresh; expect the desktop-app path
  most of the time.
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
| `claudeSelfRefresh` | false | let UsageBar refresh the Claude sign-in itself (see above before enabling) |
| `claudeUserAgentFallback` | `claude-code/2.1.220` | User-Agent for the Claude usage endpoint when no `claude` binary is around to ask |
| `claudeAppHistory`, `codexAuthPath`, `logDir` | see file | where the inputs and the history log live |

Edit, then run `./install.sh`.

## Troubleshooting

- The ✱ ⬡ item never appears: macOS 26 may have it switched off under System Settings › Menu Bar › Allow in
  the Menu Bar.
- Numbers look wrong or stale: `tail ~/Library/Logs/usagebar.log`, then run the self-test
  (`~/Applications/UsageBar.app/Contents/MacOS/UsageBar --once` for the installed copy) to see exactly what
  each source returns.
- "Claude: no data": open the Claude desktop app once so it writes a sample, or sign the CLI in.

## Project layout

```
UsageBar.swift               the whole app: Config, Claude and Codex fetchers, menu, notifications, --once self-test
Info.plist                   bundle metadata; LSUIElement (no Dock icon), LSMinimumSystemVersion 14.0
build.sh                     swiftc → build/UsageBar.app; Command Line Tools only, targets the host architecture
install.sh                   build, copy to ~/Applications, write the LaunchAgent, start it, optionally commit + push (safe to re-run)
uninstall.sh                 stop it, remove the LaunchAgent and the app
com.bsnydr.usagebar.plist    LaunchAgent template; install.sh replaces __HOME__ and writes it to ~/Library/LaunchAgents
.github/workflows/tests.yml  build + --once smoke test on a macOS runner
```

The bundle id and launchd label are `com.bsnydr.usagebar`. To use your own, change it in `Info.plist`, the
plist filename and its `Label` and `AssociatedBundleIdentifiers` keys, `install.sh` and `uninstall.sh`
together.

## License

MIT — see [`LICENSE`](LICENSE).
