# ClaudeDeck

A native macOS home for your [Claude Code](https://claude.com/claude-code)
sessions: one window with every session, live status tags, and a real
embedded terminal — plus a menu bar overview that's always a click away.

## The window

Open ClaudeDeck (menu bar icon → **Open ClaudeDeck**, or ⌘N for a new
session) and you get:

- **Sidebar with every session** — status dot, name, project folder, task
  progress (`3/5`), and a status tag: `running` / `needs input` / `idle` /
  `completed`
- **An embedded terminal** — sessions started in ClaudeDeck (**＋ New
  Session**: pick a folder, confirm the command) run right in the window.
  Click a session in the sidebar to switch to it instantly; it's a full
  terminal (xterm.js on a real pty), so you use Claude Code exactly as in
  any terminal.
- **External sessions listed too** — sessions running in Terminal.app or
  Cursor appear under "External terminals"; clicking one focuses the exact
  Terminal.app tab (tty-matched) or the project's Cursor window.

Right-click a ClaudeDeck session to end it or remove it from the list.
Closing the window leaves sessions running; quitting the app warns you if
any ClaudeDeck-hosted sessions are still alive (external ones are never
touched).

## The menu bar

- `terminal` outline — all sessions idle; filled — something is running
- a red count appears the moment any session **needs your input**
- the dropdown lists every session with its status; click to jump to it
- a daily update check adds an "⬆ Update available" item when there's a
  new release

## Why can't it embed my existing Terminal/Cursor sessions?

A terminal session's pty is a private file descriptor owned by the app that
created it; macOS offers no way for another app to attach to or mirror it.
So sessions born in Terminal.app or Cursor can only be *focused*, not
embedded. Sessions you start inside ClaudeDeck are hosted on ClaudeDeck's
own ptys — that's what makes the embedded terminal possible. (If you want
the same session visible in several terminals at once, that's what tmux is
for.)

## Install

### Homebrew

```sh
brew install --cask belkacem759/tap/claude-deck
xattr -dr com.apple.quarantine /Applications/ClaudeDeck.app
```

(The `xattr` line clears Gatekeeper quarantine — needed because the app is
not notarized.)

### Direct download

Grab `ClaudeDeck-<version>.zip` from the
[latest release](https://github.com/belkacem759/claude-deck/releases/latest),
unzip, move `ClaudeDeck.app` to `/Applications`, and clear quarantine as
above.

Launch at login: System Settings → General → Login Items → add ClaudeDeck.

On first click of a Terminal.app session, macOS asks "ClaudeDeck wants to
control Terminal" — allow it (that's the AppleScript tab-focus permission).

## Build from source

```sh
./build.sh          # current arch
./build.sh --universal
open ClaudeDeck.app
```

Requires only Xcode Command Line Tools — plain clang, Objective-C, no Xcode
project. The terminal view is [xterm.js](https://xtermjs.org) (vendored in
`Resources/vendor/`) in a WKWebView, bridged to ptys the app owns.

## Test

```sh
./test.sh                                              # unit tests (scan, status, pty)
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --selftest  # window + JS bridge + pty smoke test
```

More debug helpers:

```sh
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --print       # dump scanned sessions
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --host <pid>  # detected terminal host + tty
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --version
```

## How status works

Claude Code maintains per-session state on disk; ClaudeDeck reads it every
2 seconds — no hooks, no config:

- `~/.claude/sessions/<pid>.json` — status (`busy` / `waiting` / `idle`),
  session name, project cwd, last update. Files whose pid is no longer
  alive are ignored.
- `~/.claude/tasks/<sessionId>/*.json` — the session's task list, used for
  the `n/m` progress chip.

These paths are undocumented Claude Code internals; if a Claude Code update
changes them and the list goes empty, please open an issue.

## Releasing (maintainers)

1. Bump `VERSION` and update `CHANGELOG.md`
2. Commit, then tag and push: `git tag v<version> && git push --tags`
3. CI builds a universal binary, runs tests + the UI selftest, creates the
   GitHub release, and updates the Homebrew cask (needs the
   `TAP_GITHUB_TOKEN` repo secret — a PAT with `repo` scope on
   `homebrew-tap`)

## License

MIT (xterm.js is also MIT-licensed, © The xterm.js authors)
