# Changelog

## v2.0.0 — 2026-07-01

ClaudeDeck is now a full session workspace, not just a menu bar list.

- **Main window**: session sidebar + embedded terminal (xterm.js on
  app-owned ptys). Start Claude Code sessions inside ClaudeDeck and switch
  between them with a click.
- External sessions (Terminal.app / Cursor) listed in the same sidebar;
  clicking focuses their host window as before.
- ⌘N new session (pick folder + command, both remembered), right-click to
  end/remove sessions, quit confirmation while sessions are running.
- Menu bar dropdown gains "Open ClaudeDeck"; clicking an app-hosted session
  there jumps to it in the window.
- New `--selftest` smoke test (window + JS bridge + pty), also run in CI.

## v1.0.0 — 2026-07-01

Initial release.

- Menu bar list of all running Claude Code sessions
- Live status tags: running / needs input / idle / completed, plus `n/m` task progress
- Needs-input count badge on the menu bar icon
- Click a session to focus its terminal (exact Terminal.app tab via tty match;
  Cursor window by project folder)
- Daily update check against GitHub releases
