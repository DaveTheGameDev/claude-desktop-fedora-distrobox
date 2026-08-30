# Changelog

## 1.0.0 — 2026-08-30

First packaged release.

- **RPM package** (`claude-desktop-distrobox`) — download, double-click, done. Pulls in
  distrobox, podman and zenity as dependencies. Installs `claude-desktop-setup` and a
  **Claude Desktop Setup** app-menu entry.
- **GUI setup app** (`--gui`): install (optionally sharing one folder), update, turn the
  weekly auto-update on/off, repair the launcher, rebuild the container, remove — all with
  progress dialogs.
- **"Attach file" and drag-and-drop work out of the box.** The app is handed real host paths
  (`/home/you/Documents/…`), so the standard user folders are bind-mounted at their real paths —
  `~/Documents`, `~/Desktop`, `~/Pictures` read-only, `~/Downloads` read-write — and linked into
  the dedicated home / GTK sidebar so the file picker lands on them. `--no-user-dirs` opts out.
- `--recreate` action (GUI: **Rebuild the container**) to rebuild the container with the
  current options while keeping login and data; containers made by pre-release builds need it
  once to get the folder mounts.
- **Suspend/resume safe.** After waking on a different network the launcher notices the
  container's stale IP address (pasta copies it once at start) and restarts the container; the
  weekly auto-update timer waits 30 s after a wake-triggered start so it doesn't race the network.
  The app is also given the host's system D-Bus (`--no-system-bus` to opt out) so Electron gets
  logind's real suspend/resume events instead of inferring them from a late timer.
- **Check for updates** action on the Claude launcher (right-click the dock/app icon).
- **Desktop notification** after the weekly auto-update runs (`--notify`).
- **Self-update check** against GitHub Releases (`--check-self-update`), only on request.
- `--version`, `--install` flags.
- `DEBIAN_FRONTEND` reaches apt through sudo; stale icon files are pruned on update; update
  output is logged to a file so timer runs no longer die on SIGPIPE.
