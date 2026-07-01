# ClaudeDeck

Native macOS menu bar app that shows all your running [Claude Code](https://claude.com/claude-code)
sessions in one place — live status, task progress, and click-to-jump to the
right terminal.

Running many Claude Code sessions at once means constantly cycling through
terminal tabs to see which one finished or is waiting on you. ClaudeDeck puts
that in your menu bar.

## Features

- **One list, every session** — session name, project folder, last activity
- **Live status tags** — `running` / `needs input` / `idle` / `completed`,
  plus an `n/m` chip when the session has a task list
- **Needs-input badge** — a red count on the menu bar icon the moment any
  session is waiting on you
- **Click to jump** — focuses the exact Terminal.app window/tab (matched by
  tty); for Cursor's integrated terminal it focuses the project's window
- **Zero config** — reads the session state Claude Code already maintains;
  no hooks, no daemon, no setup
- **Update check** — pings GitHub releases once a day and shows an
  "Update available" menu item when there's a new version

## Install

### Homebrew

```sh
brew install --cask belkacem759/tap/claude-deck --no-quarantine
```

### Direct download

Grab `ClaudeDeck-<version>.zip` from the
[latest release](https://github.com/belkacem759/claude-deck/releases/latest),
unzip, and move `ClaudeDeck.app` to `/Applications`.

The app is not notarized (no Apple Developer subscription). If macOS blocks
the first launch, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/ClaudeDeck.app
```

Launch at login: System Settings → General → Login Items → add ClaudeDeck.

### First click on a Terminal.app session

macOS will ask "ClaudeDeck wants to control Terminal" — allow it. That's the
AppleScript permission used to focus the exact tab.

## Build from source

```sh
./build.sh          # current arch
./build.sh --universal
open ClaudeDeck.app
```

Requires only Xcode Command Line Tools (plain clang — no Xcode project, no
dependencies).

## Test

```sh
./test.sh
```

Debug helpers:

```sh
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --print       # dump scanned sessions
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --host <pid>  # detected terminal host + tty
./ClaudeDeck.app/Contents/MacOS/ClaudeDeck --version
```

## How it works

Claude Code maintains per-session state on disk; ClaudeDeck just reads it
every 2 seconds:

- `~/.claude/sessions/<pid>.json` — status (`busy` / `waiting` / `idle`),
  session name, project cwd, last update. Files whose pid is no longer alive
  are ignored.
- `~/.claude/tasks/<sessionId>/*.json` — the session's task list, used for
  the `n/m` progress chip.

These paths are undocumented Claude Code internals; if a Claude Code update
changes them and the list goes empty, please open an issue.

## Releasing (maintainers)

1. Bump `VERSION` and update `CHANGELOG.md`
2. Commit, then tag and push: `git tag v<version> && git push --tags`
3. CI builds a universal binary, runs tests, creates the GitHub release, and
   updates the Homebrew cask (needs the `TAP_GITHUB_TOKEN` repo secret — a
   PAT with `repo` scope on `homebrew-tap`)

## License

MIT
