# Changelog

## 1.0.0 — 2026-08-28

First packaged release.

- **RPM package** (`claude-desktop-distrobox`) — download, double-click, done. Pulls in
  distrobox, podman and zenity as dependencies. Installs `claude-desktop-setup` and a
  **Claude Desktop Setup** app-menu entry.
- **GUI setup app** (`--gui`): install (optionally sharing one folder), update, turn the
  weekly auto-update on/off, repair the launcher, remove — all with progress dialogs.
- **Check for updates** action on the Claude launcher (right-click the dock/app icon).
- **Desktop notification** after the weekly auto-update runs (`--notify`).
- **Self-update check** against GitHub Releases (`--check-self-update`), only on request.
- `--version`, `--install` flags.
- Fixes: `DEBIAN_FRONTEND` now reaches apt through sudo; stale icon files are pruned on
  update; update output is logged to a file so timer runs no longer die on SIGPIPE.
