#!/usr/bin/env bash
#
# install-claude-desktop-distrobox.sh
#
# Run Anthropic's OFFICIAL Claude desktop app on Fedora / RHEL-family Linux via
# distrobox, with privacy hardening.
#
# Anthropic ships an official Linux build only for Debian/Ubuntu. This script
# creates an Ubuntu container with distrobox, installs Anthropic's *genuine*,
# GPG-signed .deb from Anthropic's own apt repository inside it (verifying the
# signing-key fingerprint against the value published in Anthropic's docs
# *before* the repo is ever used), and wires a launcher into your Fedora host.
#
# ---------------------------------------------------------------------------
# TRUST MODEL (read this)
# ---------------------------------------------------------------------------
# * The app and its apt repo are Anthropic's own and GPG-signed. This script
#   verifies the signing key's fingerprint before enabling the repo, so a
#   tampered mirror or MITM cannot slip in a different key. No third-party
#   repackaging is involved.
# * Beyond Anthropic you trust: distrobox and podman — mature, distro-packaged,
#   rootless tools.
#
# ISOLATION MODEL (what this does and does NOT protect):
# * distrobox is built for *integration*, not sandboxing. By DEFAULT it mounts
#   your whole $HOME and shares your network — i.e. no meaningful isolation.
# * This script hardens that with two opt-out knobs:
#     --isolate-home (default): the container gets a DEDICATED home dir, so the
#        app's file dialogs, config, cache and any indexing see only that home
#        plus folders you explicitly --share. Your real ~/.ssh, ~/Documents,
#        browser profiles, etc. are not presented to the app.
#     --isolate-net  (default): the container gets its OWN network namespace.
#        It keeps full outbound internet (to reach Claude's servers) but cannot
#        reach services bound to your host's localhost.
# * HONEST CAVEAT: this is *practical* least-privilege, not a hard security
#   boundary. distrobox still bind-mounts the host root at /run/host, so a
#   determined process could reach host files through that path. Treat this as
#   "don't casually expose my whole home to a trusted-but-networked app,"
#   NOT as "sandbox untrusted code." For a hard boundary use a VM.
#
#   Install:    ./install-claude-desktop-distrobox.sh
#   Share dirs: ./install-claude-desktop-distrobox.sh --share ~/Projects --share ~/Notes
#   Update:     ./install-claude-desktop-distrobox.sh --update
#   Remove:     ./install-claude-desktop-distrobox.sh --remove   [--purge]
#   Help:       ./install-claude-desktop-distrobox.sh --help
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config / defaults
# ---------------------------------------------------------------------------
VERSION="1.2.0"                # keep in sync with the git tag vX.Y.Z (CI enforces)
REPO_SLUG="DaveTheGameDev/claude-desktop-fedora-distrobox"
RELEASES_URL="https://github.com/$REPO_SLUG/releases/latest"
RELEASES_API="https://api.github.com/repos/$REPO_SLUG/releases/latest"

NAME="claude-desktop"          # distrobox container name
IMAGE="ubuntu:24.04"           # base image (Ubuntu 22.04+ / Debian 12+ required)
ACTION="install"               # install | update | remove | print-inner
SANDBOX=0                      # 0 => launch with --no-sandbox (reliable in a
                               #      rootless container); 1 => keep Chromium's
                               #      sandbox (needs nested userns; often fails)
ISOLATE_HOME=1                 # 1 => dedicated container home (privacy)
ISOLATE_NET=1                  # 1 => own network namespace (privacy)
FULL_UPGRADE=0                 # update: also apt-upgrade the container's base OS
PURGE=0                        # remove: also delete the dedicated home dir
GUI=0                          # 1 => zenity dialogs instead of terminal prompts
NOTIFY=0                       # 1 => desktop notification when an update finishes
TIMER_EVERY="weekly"           # install-timer: daily | weekly | monthly
TIMER_TOOL_CHECK=0             # install-timer: also run the notify-only
                               #      setup-tool update check on the schedule
ACTION_SET=0                   # whether an explicit action flag was given
BOX_HOME="$HOME/.local/share/claude-desktop-box"   # dedicated container home
REAL_HOME="$HOME"              # the real host home (never mounted when isolating)
declare -a SHARES=()           # extra host dirs to expose (repeatable --share)
USER_DIRS=1                    # 1 => expose the standard XDG user folders
                               #      (Documents/Desktop/Pictures read-only,
                               #      Downloads read-write) at their REAL host
                               #      paths, so "Attach file" and drag-and-drop
                               #      from the host file manager work. Files
                               #      dropped on the window arrive as host
                               #      paths (file:///home/you/...); if those
                               #      paths do not exist inside the container
                               #      the drop and the import silently fail.
declare -a USER_DIR_MOUNTS=()  # resolved "<path>:<ro|rw>" entries (filled at create)
SYSTEM_BUS=1                   # 1 => hand the app the host's SYSTEM D-Bus so it
                               #      gets logind's real suspend/resume signals
                               #      (distrobox only forwards the session bus)

# Anthropic's signing-key fingerprint, from the official docs
# (https://code.claude.com/docs/en/desktop-linux). The in-container script
# carries its own copy (heredoc); this one is the documented reference value.
# shellcheck disable=SC2034
EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# Host-side launcher artifacts (created by us; not distrobox-export).
HOST_BIN="$HOME/.local/bin/claude-desktop"
HOST_DESKTOP="$HOME/.local/share/applications/claude-desktop.desktop"
HOST_ICON_DIR="$HOME/.local/share/icons"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YEL=""; C_RED=""; C_OFF=""
fi
log()  { printf '%s==>%s %s\n'      "$C_BLUE" "$C_OFF" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YEL"  "$C_OFF" "$*" >&2; }
die()  {
  printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  have_gui && zenity --error --width=420 --title="Claude Desktop Setup" --text="$*" 2>/dev/null
  exit 1
}

# ---------------------------------------------------------------------------
# GUI helpers (zenity). Everything here is a no-op / plain print without --gui,
# so the CLI behaviour is unchanged.
# ---------------------------------------------------------------------------
GUI_TITLE="Claude Desktop Setup"
have_gui() { [[ $GUI -eq 1 ]] && command -v zenity >/dev/null 2>&1; }
gui_info()     { zenity --info     --width=460 --title="$GUI_TITLE" --text="$1" 2>/dev/null || true; }
gui_warn()     { zenity --warning  --width=460 --title="$GUI_TITLE" --text="$1" 2>/dev/null || true; }
gui_question() { zenity --question --width=460 --title="$GUI_TITLE" --text="$1" 2>/dev/null; }

# Desktop notification (libnotify). Silent no-op when notify-send is missing or
# no session bus is reachable — the journal still has the full log.
notify_user() {
  [[ $NOTIFY -eq 1 ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send -a "Claude Desktop" -i claude-desktop "$1" "${2:-}" 2>/dev/null || true
}

# Run this very script with the given arguments behind a pulsating progress
# dialog. Output is captured to a log; on failure the log is shown. Returns the
# child's exit status. Used only by the GUI menu.
SELF="$(readlink -f "$0")"
run_with_progress() {
  local title="$1"; shift
  local logf rc
  logf="$(mktemp)"
  # `--gui` is passed so nested prompts (e.g. the restart question) use dialogs.
  # Read PIPESTATUS straight after the pipeline — an appended `|| true` would
  # overwrite it with its own status.
  set +e
  "$SELF" "$@" --gui --name "$NAME" 2>&1 | tee "$logf" \
    | zenity --progress --pulsate --auto-close --no-cancel --width=460 \
             --title="$GUI_TITLE" --text="$title" 2>/dev/null
  rc="${PIPESTATUS[0]}"
  set -e
  if [[ $rc -ne 0 ]]; then
    zenity --text-info --width=720 --height=480 --title="$GUI_TITLE — failed" \
           --filename="$logf" 2>/dev/null || true
  fi
  rm -f "$logf"
  return "$rc"
}

usage() {
  cat <<'EOF'
Run the official Claude desktop app on Fedora via distrobox (privacy-hardened).

Usage:
  install-claude-desktop-distrobox.sh [action] [options]

Actions:
  --install        Create the container and install Claude + host launcher
  (default)        (this is what happens with no action flag).
  --update         Update Claude inside the existing container.
                   Add --full to also apt-upgrade the container's base OS.
  --remove         Remove the container, the host launcher, and the timer.
  --recreate       Rebuild the container from scratch with the current options
                   (keeps your login and data in the dedicated home). Use it
                   after upgrading this tool, or to change --share/--user-dirs
                   choices, since bind mounts are fixed when the container is
                   created.
  --refresh-launcher
                   Rebuild only the host launcher, .desktop entry and icons
                   from the app already installed in the container. Use this
                   if the dock shows a second, icon-less entry for the running
                   window instead of reusing the launcher's icon.
  --install-timer  Enable a systemd *user* timer that auto-updates Claude +
                   the container's base OS (runs --update --full). Weekly by
                   default; add --every daily|weekly|monthly to choose. Run it
                   again with a different --every to change the frequency.
  --remove-timer   Disable and remove that timer.
  --check-self-update
                   Ask GitHub whether a newer release of this setup tool
                   exists (only ever runs when you invoke it). If you
                   installed the RPM, offers to download, verify and
                   install it (polkit password prompt).
  --self-update    Same, but installs a newer release without asking.
  --version        Print the setup tool version and exit.

GUI options:
  --gui            Use the graphical setup app instead of terminal prompts.
                   Alone, opens the "Claude Desktop Setup" window (native GTK4,
                   falling back to zenity buttons); combined with an action
                   (e.g. --update --gui) runs that action with zenity dialogs.
  --tool-check     With --install-timer: the timer also asks GitHub whether a
                   newer setup tool exists and shows a notification.
                   Notify-only — it never installs anything by itself.
  --notify         Send a desktop notification when an update finishes
                   (used by the auto-update timer).

Privacy options (defaults are the hardened choices):
  --isolate-home   Give the container a dedicated home dir (default).
  --full-home      Opt out: mount your real $HOME into the container.
  --isolate-net    Give the container its own network namespace (default).
  --share-net      Opt out: share the host network namespace.
  --share <dir>    Expose a host directory to the app (repeatable). Use this to
                   let Cowork/Code work on specific project folders while the
                   rest of your home stays hidden.
  --user-dirs      Expose your standard folders at their real paths (default):
                   ~/Documents, ~/Desktop, ~/Pictures read-only and ~/Downloads
                   read-write. Needed for "Attach file" and drag-and-drop from
                   your file manager, which hand the app real host paths.
  --no-user-dirs   Opt out: hide those folders too (attach/drop only work for
                   files under the dedicated home or a --share dir).
  --box-home <dir> Where the dedicated home lives (default:
                   ~/.local/share/claude-desktop-box).
  --no-system-bus  Do not expose the host's system D-Bus to the app. By default
                   the launcher points it at /run/host/run/dbus/system_bus_socket
                   so Electron receives logind's suspend/resume signals; without
                   them the app only guesses that the machine slept, and in-flight
                   status (e.g. a running session's timer) can stay stale after a
                   wake. The system bus also exposes NetworkManager/UPower state.

Other options:
  --sandbox        Keep Chromium's sandbox enabled (default: --no-sandbox).
  --name <name>    Container name (default: claude-desktop).
  --image <image>  Base image (default: ubuntu:24.04; needs Ubuntu 22.04+).
  --purge          With --remove, also delete the dedicated home dir (data!).
  --print-inner    Print the in-container install script and exit (for review).
  -h, --help       Show this help and exit.

After install: search "Claude" in your app menu, or run `claude-desktop`.
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# In-container scripts. Passed to the box via `bash -c "$(...)"` so they do not
# depend on any host path being mounted (important with an isolated home).
# ---------------------------------------------------------------------------
emit_install_inner() {
  cat <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
# sudo's env_reset would strip an exported DEBIAN_FRONTEND, so pass it on the
# command line of every apt call instead.
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get"
EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

echo "==> [container] Installing prerequisites..."
$APT update -y
$APT install -y curl ca-certificates gnupg

echo "==> [container] Downloading Anthropic's signing key..."
sudo curl -fsSLo /usr/share/keyrings/claude-desktop-archive-keyring.asc \
  https://downloads.claude.ai/claude-desktop/key.asc

echo "==> [container] Verifying key fingerprint (before enabling the repo)..."
got_fpr="$(gpg --show-keys --with-colons \
  /usr/share/keyrings/claude-desktop-archive-keyring.asc \
  | awk -F: '/^fpr:/{print $10; exit}')"
if [ "$got_fpr" != "$EXPECTED_FPR" ]; then
  echo "ERROR: signing-key fingerprint mismatch — aborting." >&2
  echo "  expected: $EXPECTED_FPR" >&2
  echo "  got:      ${got_fpr:-<none>}" >&2
  # Do not leave a repo wired to an unverified key.
  sudo rm -f /usr/share/keyrings/claude-desktop-archive-keyring.asc
  exit 1
fi
echo "    OK: $got_fpr"

echo "==> [container] Registering Anthropic apt repository..."
echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/claude-desktop-archive-keyring.asc] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
  | sudo tee /etc/apt/sources.list.d/claude-desktop.list >/dev/null

echo "==> [container] Installing claude-desktop..."
$APT update -y
$APT install -y claude-desktop
echo "==> [container] Install complete."
INNER
}

emit_update_inner() {
  cat <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
# sudo's env_reset would strip an exported DEBIAN_FRONTEND, so pass it on the
# command line of every apt call instead.
APT="sudo DEBIAN_FRONTEND=noninteractive apt-get"
echo "==> [container] Updating claude-desktop..."
ver_before="$(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo none)"
$APT update -y
$APT install -y --only-upgrade claude-desktop
ver_after="$(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo none)"
echo "META:VER_BEFORE=$ver_before"
echo "META:VER_AFTER=$ver_after"
if [ "$ver_before" = "$ver_after" ]; then
  echo "==> [container] claude-desktop is already the newest version ($ver_after)."
  echo "META:UPDATED=0"
else
  echo "==> [container] claude-desktop updated: $ver_before -> $ver_after"
  echo "META:UPDATED=1"
fi
if [ "${FULL_UPGRADE:-0}" = "1" ]; then
  echo "==> [container] Applying base OS security patches (apt upgrade)..."
  $APT upgrade -y
  $APT autoremove -y --purge
  $APT clean
fi
echo "==> [container] Update complete."
INNER
}

# Prints machine-readable facts about the installed app (binary, .desktop, icon).
# CLAUDE_ICON= lines list every themed icon the app ships, so the host can
# rebuild a proper hicolor theme tree instead of dropping one loose file.
emit_meta_inner() {
  cat <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
bin_path="$(command -v claude-desktop || true)"
desktop_src="$(find /usr/share/applications -maxdepth 1 -iname '*claude*.desktop' 2>/dev/null | head -n1 || true)"
icon_name=""
wmclass=""
if [ -n "$desktop_src" ]; then
  icon_name="$(grep -m1 '^Icon=' "$desktop_src" | cut -d= -f2- || true)"
  wmclass="$(grep -m1 '^StartupWMClass=' "$desktop_src" | cut -d= -f2- || true)"
fi
icon_file=""
if [ -n "$icon_name" ]; then
  if [ -f "$icon_name" ]; then
    icon_file="$icon_name"
  else
    for sz in 512x512 256x256 128x128 scalable 64x64; do
      f="$(find "/usr/share/icons/hicolor/$sz/apps" -iname "${icon_name}.*" 2>/dev/null | head -n1 || true)"
      [ -n "$f" ] && { icon_file="$f"; break; }
    done
    [ -z "$icon_file" ] && icon_file="$(find /usr/share/icons /usr/share/pixmaps -iname "${icon_name}.*" 2>/dev/null | head -n1 || true)"
  fi
fi
echo "META:CLAUDE_BIN=${bin_path}"
echo "META:CLAUDE_DESKTOP_SRC=${desktop_src}"
echo "META:CLAUDE_ICON_FILE=${icon_file}"
echo "META:CLAUDE_ICON_NAME=${icon_name}"
echo "META:CLAUDE_WMCLASS=${wmclass}"
if [ -n "$icon_name" ] && [ ! -f "$icon_name" ]; then
  find /usr/share/icons/hicolor -path '*/apps/*' \
       \( -iname "${icon_name}.png" -o -iname "${icon_name}.svg" \) 2>/dev/null \
    | sort | sed 's/^/META:CLAUDE_ICON=/'
fi
INNER
}

# ---------------------------------------------------------------------------
# Auto-update timer (optional): a systemd *user* timer that runs
# `--update --full` weekly. Units are generated with this script's own
# absolute path, so they keep working wherever the repo lives.
# ---------------------------------------------------------------------------
TIMER_NAME="claude-desktop-update"
timer_frequency() {
  # Print daily|weekly|monthly from the installed timer unit (empty if none).
  sed -n 's/^OnCalendar=//p' "$HOME/.config/systemd/user/${TIMER_NAME}.timer" 2>/dev/null
}
timer_tool_check() {
  # Does the installed timer also run the notify-only setup-tool check?
  grep -qs -- '--self-check-notify' "$HOME/.config/systemd/user/${TIMER_NAME}.service"
}
install_timer() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this needs a systemd user session."
  case "$TIMER_EVERY" in daily|weekly|monthly) ;; *) die "--every must be daily, weekly or monthly (got '$TIMER_EVERY')" ;; esac
  local self unitdir toolexec=""
  self="$(readlink -f "$0")"
  unitdir="$HOME/.config/systemd/user"
  mkdir -p "$unitdir"
  # Opt-in second step: ask GitHub whether a newer setup tool exists and send
  # a desktop notification. Notify-only — nothing is ever installed by itself.
  [[ $TIMER_TOOL_CHECK -eq 1 ]] && toolexec="ExecStart=/bin/bash $self --self-check-notify"
  cat > "$unitdir/${TIMER_NAME}.service" <<EOF
[Unit]
Description=Update Claude Desktop (distrobox) + container base OS security patches
Documentation=file://$self

[Service]
Type=oneshot
# Persistent=true replays a missed run the instant the machine resumes, which
# can land inside the few seconds before the network is back up. Wait it out.
ExecStartPre=/usr/bin/sleep 30
ExecStart=/bin/bash $self --update --full --notify --name $NAME
$toolexec
TimeoutStartSec=1800
EOF
  cat > "$unitdir/${TIMER_NAME}.timer" <<EOF
[Unit]
Description=Claude Desktop update (distrobox) + base OS patches, $TIMER_EVERY

[Timer]
OnCalendar=$TIMER_EVERY
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${TIMER_NAME}.timer"
  if [[ $TIMER_TOOL_CHECK -eq 1 ]]; then
    log "Auto-update timer installed and enabled ($TIMER_EVERY; also checks for setup-tool updates)."
  else
    log "Auto-update timer installed and enabled ($TIMER_EVERY)."
  fi
  log "Logs: journalctl --user -u ${TIMER_NAME}"
  systemctl --user list-timers "${TIMER_NAME}.timer" --no-pager 2>/dev/null || true
}
remove_timer() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user disable --now "${TIMER_NAME}.timer" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/${TIMER_NAME}.timer" \
        "$HOME/.config/systemd/user/${TIMER_NAME}.service"
  systemctl --user daemon-reload 2>/dev/null || true
  log "Auto-update timer removed."
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)        ACTION="install"; ACTION_SET=1; shift ;;
    --update)         ACTION="update"; ACTION_SET=1; shift ;;
    --refresh-launcher) ACTION="refresh-launcher"; ACTION_SET=1; shift ;;
    --remove)         ACTION="remove"; ACTION_SET=1; shift ;;
    --recreate)       ACTION="recreate"; ACTION_SET=1; shift ;;
    --install-timer)  ACTION="install-timer"; ACTION_SET=1; shift ;;
    --remove-timer)   ACTION="remove-timer"; ACTION_SET=1; shift ;;
    --print-inner)    ACTION="print-inner"; ACTION_SET=1; shift ;;
    --check-self-update) ACTION="self-check"; ACTION_SET=1; shift ;;
    --self-update)  ACTION="self-update"; ACTION_SET=1; shift ;;
    --self-check-notify) ACTION="self-check-notify"; ACTION_SET=1; shift ;;
    --version)      printf '%s\n' "$VERSION"; exit 0 ;;
    --gui)          GUI=1; shift ;;
    --notify)       NOTIFY=1; shift ;;
    --every)        TIMER_EVERY="${2:?--every requires daily|weekly|monthly}"; shift 2 ;;
    --tool-check)   TIMER_TOOL_CHECK=1; shift ;;
    --sandbox)      SANDBOX=1; shift ;;
    --isolate-home) ISOLATE_HOME=1; shift ;;
    --full-home)    ISOLATE_HOME=0; shift ;;
    --isolate-net)  ISOLATE_NET=1; shift ;;
    --share-net)    ISOLATE_NET=0; shift ;;
    --full)         FULL_UPGRADE=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --share)        SHARES+=("${2:?--share requires a directory}"); shift 2 ;;
    --user-dirs)    USER_DIRS=1; shift ;;
    --no-user-dirs) USER_DIRS=0; shift ;;
    --no-system-bus) SYSTEM_BUS=0; shift ;;
    --box-home)     BOX_HOME="${2:?--box-home requires a path}"; shift 2 ;;
    --name)         NAME="${2:?--name requires a value}"; shift 2 ;;
    --image)        IMAGE="${2:?--image requires a value}"; shift 2 ;;
    -h|--help)      usage ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
done

if [[ "$ACTION" == "print-inner" ]]; then
  emit_install_inner
  exit 0
fi

# `--gui` with no explicit action opens the menu.
if [[ $GUI -eq 1 && $ACTION_SET -eq 0 ]]; then ACTION="gui-menu"; fi
if [[ $GUI -eq 1 ]] && ! command -v zenity >/dev/null 2>&1; then
  warn "--gui requested but zenity is not installed (dnf install zenity); using terminal output."
  GUI=0
  [[ "$ACTION" == "gui-menu" ]] && die "The setup menu needs zenity. Install it or use the command-line flags (--help)."
fi

# Timer management is host-side (systemd) only — no container needed.
if [[ "$ACTION" == "install-timer" ]]; then install_timer; exit 0; fi
if [[ "$ACTION" == "remove-timer" ]]; then remove_timer; exit 0; fi

# ---------------------------------------------------------------------------
# Self-update: one request to the GitHub Releases API, only when the user
# asks for it (menu row, --check-self-update or --self-update) or — strictly
# opt-in, via --tool-check on the auto-update timer — as a scheduled
# notify-only check that never installs anything by itself. RPM installs can upgrade in place (download + sha256 check +
# pkexec dnf); git checkouts are just pointed at the releases page.
# ---------------------------------------------------------------------------
# Installed from the RPM (as opposed to a git checkout)? Only then can we
# upgrade in place: download the release RPM, verify it, hand it to dnf.
rpm_installed() {
  [[ "$SELF" == /usr/bin/claude-desktop-setup ]] && rpm -q claude-desktop-distrobox >/dev/null 2>&1
}

# $1 = release JSON. Downloads the .noarch.rpm + SHA256SUMS of that release,
# checks the sum and installs through polkit (pkexec dnf). Returns non-zero on
# any failure; callers report.
self_update_install() {
  local json="$1" ver="$2" rpm_url sums_url dir rpm_file
  rpm_url="$(printf '%s' "$json" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\.noarch\.rpm\)".*/\1/p' | head -n1)"
  sums_url="$(printf '%s' "$json" | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\/SHA256SUMS\)".*/\1/p' | head -n1)"
  if [[ -z "$rpm_url" || -z "$sums_url" ]]; then
    warn "Release $ver has no RPM/SHA256SUMS asset — download it manually: $RELEASES_URL"
    have_gui && gui_warn "Release $ver has no RPM attached yet.\n\nSee $RELEASES_URL"
    return 1
  fi
  dir="$(mktemp -d)"
  rpm_file="$dir/${rpm_url##*/}"
  log "Downloading ${rpm_url##*/} ..."
  if ! curl -fsSL --max-time 120 -o "$rpm_file" "$rpm_url" \
     || ! curl -fsSL --max-time 30 -o "$dir/SHA256SUMS" "$sums_url"; then
    warn "Download failed."; have_gui && gui_warn "Download failed. Try again later or fetch it from\n$RELEASES_URL"
    rm -rf "$dir"; return 1
  fi
  if ! (cd "$dir" && sha256sum -c --ignore-missing --quiet SHA256SUMS >/dev/null 2>&1); then
    warn "Checksum mismatch for ${rpm_file##*/} — not installing."
    have_gui && gui_warn "The downloaded package did not match its checksum, so it was not installed."
    rm -rf "$dir"; return 1
  fi
  log "Checksum OK. Installing (polkit will ask for your password) ..."
  chmod 644 "$rpm_file"; chmod 755 "$dir"     # dnf runs as root but reads the file by path
  if ! pkexec dnf install -y "$rpm_file"; then
    warn "Install failed or was cancelled."
    have_gui && gui_warn "The update was not installed (cancelled or dnf failed).\n\nThe package is at $rpm_file if you want to install it yourself."
    return 1
  fi
  rm -rf "$dir"
  log "Claude Desktop Setup updated to $ver."
  have_gui && gui_info "Claude Desktop Setup was updated to version <b>$ver</b>.\n\nClose and reopen the setup window to use it."
  return 0
}

# $1 = "check" (ask before installing) | "update" (install without asking)
#    | "notify" (timer: desktop notification only, install nothing)
self_check() {
  local mode="${1:-check}" json tag latest
  log "Checking $REPO_SLUG for a newer release (you have $VERSION) ..."
  if ! json="$(curl -fsSL --max-time 10 -H 'Accept: application/vnd.github+json' "$RELEASES_API" 2>/dev/null)"; then
    warn "Could not reach GitHub (offline, or no release published yet)."
    have_gui && gui_warn "Could not check for updates.\n\nEither you are offline or no release has been published yet.\n\nYou have version $VERSION."
    return 0
  fi
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  latest="${tag#v}"
  [[ -n "$latest" ]] || { warn "Unexpected response from GitHub."; return 0; }
  if [[ "$latest" == "$VERSION" || "$(printf '%s\n%s\n' "$VERSION" "$latest" | sort -V | tail -n1)" != "$latest" ]]; then
    log "You have the latest version ($VERSION)."
    have_gui && gui_info "Claude Desktop Setup is up to date (version $VERSION)."
    return 0
  fi
  log "A newer version is available: $latest (you have $VERSION): $RELEASES_URL"
  if [[ "$mode" == "notify" ]]; then
    notify_user "Claude Desktop Setup $latest is available" \
      "Open Claude Desktop Setup → Check for tool update to install it."
    return 0
  fi
  if rpm_installed && command -v pkexec >/dev/null 2>&1; then
    local go=0
    if [[ "$mode" == "update" ]]; then
      go=1
    elif have_gui; then
      gui_question "Version <b>$latest</b> of Claude Desktop Setup is available (you have $VERSION).\n\nDownload and install it now? You will be asked for your password." && go=1
    else
      local reply
      read -r -p "Download and install version $latest now? [Y/n] " reply || reply=""
      [[ "$reply" =~ ^[Nn] ]] || go=1
    fi
    [[ $go -eq 1 ]] && { self_update_install "$json" "$latest" || return 1; }
  else
    # Git checkout (or no polkit): can't replace ourselves safely — point at the page.
    log "You are not running the RPM; get the new version from $RELEASES_URL"
    if have_gui && gui_question "Version <b>$latest</b> of Claude Desktop Setup is available (you have $VERSION).\n\nOpen the download page?"; then
      xdg-open "$RELEASES_URL" >/dev/null 2>&1 &
    fi
  fi
}
if [[ "$ACTION" == "self-check" ]]; then self_check check; exit; fi
if [[ "$ACTION" == "self-update" ]]; then self_check update; exit; fi
if [[ "$ACTION" == "self-check-notify" ]]; then self_check notify; exit; fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (distrobox is rootless)."

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64) : ;;
  *) die "unsupported architecture: $ARCH (need x86_64 or aarch64)." ;;
esac

HAVE_DNF=0
command -v dnf >/dev/null 2>&1 && HAVE_DNF=1

# ---------------------------------------------------------------------------
# Ensure distrobox + a container manager
# ---------------------------------------------------------------------------
ensure_tool() {
  local tool="$1" pkg="$2"
  command -v "$tool" >/dev/null 2>&1 && return 0
  [[ $HAVE_DNF -eq 1 ]] || die "'$tool' is missing and dnf isn't available. Please install '$pkg' manually."
  if have_gui && command -v pkexec >/dev/null 2>&1; then
    # No terminal for a sudo password in GUI mode — use polkit's dialog instead.
    log "Installing $pkg (polkit will ask for your password) ..."
    pkexec dnf install -y "$pkg"
  else
    log "Installing $pkg (needs sudo) ..."
    sudo dnf install -y "$pkg"
  fi
}

ensure_tool distrobox distrobox
if ! command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
  ensure_tool podman podman
fi

if command -v podman >/dev/null 2>&1; then MGR=podman; else MGR=docker; fi
container_exists() {
  if [[ "$MGR" == podman ]]; then
    podman container exists "$1"
  else
    docker inspect --type container "$1" >/dev/null 2>&1
  fi
}

# Detect whether this distrobox supports the network-isolation flag, so we can
# warn instead of failing on very old versions.
distrobox_supports_netns() {
  distrobox create --help 2>&1 | grep -q -- '--unshare-netns'
}

# ---------------------------------------------------------------------------
# Launcher metadata (queried from the container; consumed by build_host_launcher)
# ---------------------------------------------------------------------------
CLAUDE_BIN=""; DESKTOP_SRC=""; ICON_FILE=""; ICON_NAME=""; WMCLASS_SRC=""
declare -a ICON_SRCS=()

collect_launcher_meta() {
  local out
  out="$(distrobox enter --name "$NAME" -- bash -c "$(emit_meta_inner)" 2>/dev/null || true)"
  CLAUDE_BIN="$(printf   '%s\n' "$out" | sed -n 's/^META:CLAUDE_BIN=//p'         | head -n1)"
  DESKTOP_SRC="$(printf  '%s\n' "$out" | sed -n 's/^META:CLAUDE_DESKTOP_SRC=//p' | head -n1)"
  ICON_FILE="$(printf    '%s\n' "$out" | sed -n 's/^META:CLAUDE_ICON_FILE=//p'   | head -n1)"
  ICON_NAME="$(printf    '%s\n' "$out" | sed -n 's/^META:CLAUDE_ICON_NAME=//p'   | head -n1)"
  WMCLASS_SRC="$(printf  '%s\n' "$out" | sed -n 's/^META:CLAUDE_WMCLASS=//p'     | head -n1)"
  mapfile -t ICON_SRCS < <(printf '%s\n' "$out" | sed -n 's/^META:CLAUDE_ICON=//p')
  # Icon= should be a bare theme name, but tolerate a path or an extension.
  ICON_NAME="$(basename -- "$ICON_NAME")"
  case "$ICON_NAME" in *.png|*.svg|*.xpm) ICON_NAME="${ICON_NAME%.*}" ;; esac
}

# The window's real WM_CLASS, read off a live window. This is the authoritative
# value; when the app happens to be running we prefer it over anything guessed.
# X11/XWayland only — a pure-Wayland compositor exposes no such query.
detect_wmclass_from_window() {
  command -v xprop >/dev/null 2>&1 || return 1
  [[ -n "${DISPLAY:-}" ]] || return 1
  local ids id cls
  ids="$(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed -n 's/.*# //p' | tr -d ' ' | tr ',' ' ')" || return 1
  [[ -n "$ids" ]] || return 1
  for id in $ids; do
    cls="$(xprop -id "$id" WM_CLASS 2>/dev/null | sed -n 's/^WM_CLASS(STRING) = .*, "\(.*\)"$/\1/p')"
    [[ -n "$cls" ]] || continue
    case "${cls,,}" in *claude*) printf '%s\n' "$cls"; return 0 ;; esac
  done
  return 1
}

# Best-effort pixel size of a PNG, read straight from the IHDR header, so an
# untagged icon still lands in a sane hicolor bucket. Echoes e.g. "256x256".
png_dimensions() {
  local f="$1" w h
  read -r w h < <(od -An -N8 -j16 -tu4 --endian=big -- "$f" 2>/dev/null) || return 1
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && $w -gt 0 && $h -gt 0 ]] || return 1
  printf '%sx%s\n' "$w" "$h"
}

# ---------------------------------------------------------------------------
# Icons
#
# A loose ~/.local/share/icons/claude-desktop.png is enough for the launcher
# (the .desktop can point at it by absolute path) but NOT for a window: when
# the shell cannot tie a window to a .desktop entry it falls back to looking up
# the window's WM_CLASS *as an icon name* in the icon theme, and a loose file
# lives in no theme. That lookup fails and the dock draws a broken-image tile.
# So install the icons into a real hicolor tree, under every name the shell
# might ask for: the app's own icon name, our .desktop id, and the WM_CLASS.
# ---------------------------------------------------------------------------
ICON_MANIFEST="$HOME/.local/share/claude-desktop-launcher.icons"
ICON_KEY=""            # theme name to put in Icon=; empty if nothing installed

install_app_icons() {
  local wmclass="$1"
  ICON_KEY=""
  local -a names=()
  local n src rel sz ext dest tmp dim count=0

  add_icon_name() {
    local want="$1" have
    [[ -n "$want" ]] || return 0
    for have in ${names[@]+"${names[@]}"}; do [[ "$have" == "$want" ]] && return 0; done
    names+=("$want")
  }
  add_icon_name "$ICON_NAME"
  add_icon_name "claude-desktop"          # our .desktop id — the shell's other fallback
  add_icon_name "$wmclass"
  add_icon_name "${wmclass,,}"

  # Remember what the previous install wrote, so files that this version no
  # longer ships (a changed icon name, size or window class) can be pruned
  # instead of piling up across updates.
  local -a old_files=()
  [[ -f "$ICON_MANIFEST" ]] && mapfile -t old_files < "$ICON_MANIFEST"

  : > "$ICON_MANIFEST"
  tmp="$(mktemp)"

  # Every themed source the app ships, in every size it ships it in.
  local -a sources=(${ICON_SRCS[@]+"${ICON_SRCS[@]}"})
  # No themed icons (icon shipped as a bare path or a pixmap)? Use the single
  # file we found and work its size out ourselves.
  [[ ${#sources[@]} -eq 0 && -n "$ICON_FILE" ]] && sources=("$ICON_FILE")

  for src in ${sources[@]+"${sources[@]}"}; do
    "$MGR" cp "$NAME:$src" "$tmp" 2>/dev/null || continue
    ext="${src##*.}"; ext="${ext,,}"
    sz=""
    if [[ "$src" == */icons/hicolor/* ]]; then
      rel="${src#*/icons/hicolor/}"; sz="${rel%%/*}"
    fi
    if [[ ! "$sz" =~ ^([0-9]+x[0-9]+|scalable)$ ]]; then
      if [[ "$ext" == svg ]]; then
        sz="scalable"
      elif dim="$(png_dimensions "$tmp")"; then
        sz="$dim"
      else
        sz="256x256"
      fi
    fi
    for n in ${names[@]+"${names[@]}"}; do
      dest="$HOST_ICON_DIR/hicolor/$sz/apps/$n.$ext"
      mkdir -p "$(dirname "$dest")"
      cp -f "$tmp" "$dest" || continue
      printf '%s\n' "$dest" >> "$ICON_MANIFEST"
      count=$((count + 1))
    done
  done
  rm -f "$tmp"
  unset -f add_icon_name

  if [[ $count -eq 0 ]]; then
    # Nothing new landed — keep the previous manifest so --remove still works.
    if [[ ${#old_files[@]} -gt 0 ]]; then
      printf '%s\n' "${old_files[@]}" > "$ICON_MANIFEST"
    else
      rm -f "$ICON_MANIFEST"
    fi
    return 1
  fi

  local old
  for old in ${old_files[@]+"${old_files[@]}"}; do
    [[ "$old" == "$HOST_ICON_DIR/hicolor/"* ]] || continue
    grep -qxF -- "$old" "$ICON_MANIFEST" || rm -f "$old"
  done
  find "$HOST_ICON_DIR/hicolor" -type d -empty -delete 2>/dev/null || true

  # Refresh the theme cache if this tree has one; GTK falls back to scanning the
  # directories when it does not, so a failure here is not fatal.
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q -f -t "$HOST_ICON_DIR/hicolor" 2>/dev/null || true
  touch "$HOST_ICON_DIR/hicolor" 2>/dev/null || true

  ICON_KEY="${names[0]}"
  log "Installed $count icon file(s) under $HOST_ICON_DIR/hicolor (names: ${names[*]})."
}

# ---------------------------------------------------------------------------
# Host-side launcher (works with an isolated home, unlike distrobox-export)
# ---------------------------------------------------------------------------
build_host_launcher() {
  local claude_bin="$CLAUDE_BIN" desktop_src="$DESKTOP_SRC" icon_file="$ICON_FILE"

  # The window class the shell will see. Prefer a live window (ground truth),
  # then the app's own StartupWMClass, then our .desktop id — and then FORCE it
  # with Chromium's --class so the running window and StartupWMClass below can
  # never disagree. Without that match the shell treats the window as an unknown
  # app: a second, un-iconified dock entry beside the launcher. Startup
  # notification cannot rescue it either, since the activation token does not
  # survive the trip through `distrobox enter`.
  local wmclass
  if wmclass="$(detect_wmclass_from_window)"; then
    log "Detected running window class: $wmclass"
  elif [[ -n "$WMCLASS_SRC" ]]; then
    wmclass="$WMCLASS_SRC"
  else
    wmclass="claude-desktop"
  fi

  local -a appflags=()
  [[ $SANDBOX -eq 1 ]] || appflags+=("--no-sandbox")
  appflags+=("--class=$wmclass")
  local flags; flags="$(printf '%q ' "${appflags[@]}")"

  mkdir -p "$(dirname "$HOST_BIN")" "$(dirname "$HOST_DESKTOP")" "$HOST_ICON_DIR"

  # 1) Wrapper on PATH. Use the ABSOLUTE in-container binary path (not the bare
  #    name) so it can never resolve back to this very wrapper through a shared
  #    PATH entry, and force HOME to the sandbox so the app writes there.
  #    The system D-Bus is opt-out: Electron's powerMonitor (suspend/resume)
  #    and its sleep inhibitor talk to logind on the SYSTEM bus, which distrobox
  #    does not forward - it only sets DBUS_SESSION_BUS_ADDRESS. The host socket
  #    is reachable via /run/host, so tell the app where it is (guarded at run
  #    time on the socket existing; expanded by the wrapper, not here).
  local runcmd
  if [[ $ISOLATE_HOME -eq 1 ]]; then
    runcmd="$(printf 'env "${SYS_BUS[@]}" HOME=%q %q %s' "$BOX_HOME" "$claude_bin" "$flags")"
  else
    runcmd="$(printf 'env "${SYS_BUS[@]}" %q %s' "$claude_bin" "$flags")"
  fi
  log "Writing launcher: $HOST_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Auto-generated by install-claude-desktop-distrobox.sh\n'
    printf '# Launches Claude Desktop inside the "%s" distrobox container.\n' "$NAME"
    printf 'NAME=%q\n' "$NAME"
    printf 'SYSTEM_BUS=%q\n' "$SYSTEM_BUS"
    cat <<'WRAP'
# Host system D-Bus for logind suspend/resume signals (see --no-system-bus).
SYS_BUS=()
if [[ "$SYSTEM_BUS" == 1 && -S /run/dbus/system_bus_socket ]]; then
  SYS_BUS=(DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/host/run/dbus/system_bus_socket)
fi
# With an isolated network namespace, pasta copies the host's address and
# routes ONCE, when the container starts. Wake a laptop on a different network
# and the container keeps the old address: no internet until it is restarted.
# Detect that here and restart the container before entering it - unless the
# app is still running, in which case only warn (a restart would kill its window).
fix_stale_net() {
  command -v podman >/dev/null 2>&1 || return 0
  [[ "$(podman inspect "$NAME" --format '{{.HostConfig.NetworkMode}} {{.State.Running}}' 2>/dev/null)" == "pasta true" ]] || return 0
  local host_ip box_ip
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)"
  [[ -n "$host_ip" ]] || return 0                       # host is offline: nothing to compare
  box_ip="$(podman exec "$NAME" ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)"
  [[ "$box_ip" != "$host_ip" ]] || return 0
  if podman exec "$NAME" pgrep -f /usr/lib/claude-desktop >/dev/null 2>&1; then
    notify-send -a "Claude Desktop" -i claude-desktop "Claude's network is stale" \
      "The host address changed (${box_ip:-none} -> $host_ip) since Claude started. Quit Claude and launch it again to reconnect." 2>/dev/null || true
    return 0
  fi
  notify-send -a "Claude Desktop" -i claude-desktop "Refreshing Claude's network" \
    "The host address changed since the container started; restarting it." 2>/dev/null || true
  podman stop -t 10 "$NAME" >/dev/null 2>&1 || true
}
fix_stale_net
WRAP
    printf 'exec distrobox enter --name %q -- %s "$@"\n' "$NAME" "$runcmd"
  } > "$HOST_BIN"
  chmod +x "$HOST_BIN"

  # 2) Copy the app icons out of the container (podman cp is mount-independent)
  #    into a proper hicolor theme, so window icon lookups resolve too.
  install_app_icons "$wmclass" || true
  local host_icon=""
  if [[ -z "$ICON_KEY" ]]; then
    # Themed install failed — fall back to one loose file addressed by path.
    if [[ -n "$icon_file" ]]; then
      local ext="${icon_file##*.}"
      host_icon="$HOST_ICON_DIR/claude-desktop.$ext"
      if "$MGR" cp "$NAME:$icon_file" "$host_icon" 2>/dev/null; then
        log "Copied icon: $host_icon"
      else
        warn "Could not copy the app icon; the launcher will use a generic icon."
        host_icon=""
      fi
    fi
  fi
  # Icon= prefers the theme name: the shell then picks the size it needs, and
  # the same name resolves for an unmatched window.
  local icon_value="${ICON_KEY:-$host_icon}"

  # 3) Host .desktop: start from the app's own file (keeps Name/MimeType/
  #    Categories) and rewrite Exec/Icon/StartupWMClass to match our wrapper.
  log "Writing desktop entry: $HOST_DESKTOP"
  local tmp; tmp="$(mktemp)"
  if [[ -n "$desktop_src" ]] && "$MGR" cp "$NAME:$desktop_src" "$tmp" 2>/dev/null; then
    # Swap only the program in each Exec= (the main entry and any
    # [Desktop Action ...]), so per-action arguments such as --new-window
    # survive; the in-container path they used does not exist on the host.
    sed -i \
      -e "s|^Exec=[^ ]*|Exec=${HOST_BIN}|" \
      -e '/^DBusActivatable=/d' \
      -e '/^TryExec=/d' \
      "$tmp"
    if [[ -n "$icon_value" ]]; then
      sed -i -e "s|^Icon=.*|Icon=${icon_value}|" "$tmp"
    fi
    if grep -q '^StartupWMClass=' "$tmp"; then
      sed -i -e "s|^StartupWMClass=.*|StartupWMClass=${wmclass}|" "$tmp"
    else
      # Insert into [Desktop Entry], not at EOF — the file may end in a
      # [Desktop Action ...] group, where the key would be ignored.
      sed -i -e "0,/^\[Desktop Entry\]/s|^\[Desktop Entry\]|[Desktop Entry]\nStartupWMClass=${wmclass}|" "$tmp"
    fi
    cp "$tmp" "$HOST_DESKTOP"
  else
    # Fallback: synthesize a minimal entry.
    {
      printf '[Desktop Entry]\nType=Application\nName=Claude\n'
      printf 'Exec=%s %%U\n' "$HOST_BIN"
      [[ -n "$icon_value" ]] && printf 'Icon=%s\n' "$icon_value"
      printf 'StartupWMClass=%s\n' "$wmclass"
      printf 'Terminal=false\nCategories=Utility;Network;\n'
    } > "$HOST_DESKTOP"
  fi
  rm -f "$tmp"

  # 3b) A right-click "Check for updates" action on the launcher, pointing back
  #     at this very script (RPM: /usr/bin/claude-desktop-setup; git clone: its
  #     path). Runs the update with dialogs, so no terminal is ever needed.
  #     A second action, "Settings", opens the full setup menu.
  local update_exec settings_exec
  update_exec="$(printf '%q --update --full --gui --name %q' "$SELF" "$NAME")"
  settings_exec="$(printf '%q --gui --name %q' "$SELF" "$NAME")"
  sed -i -e '/^\[Desktop Action Update\]/,/^$/d' \
         -e '/^\[Desktop Action Settings\]/,/^$/d' "$HOST_DESKTOP"   # drop stale copies
  local act
  for act in Update Settings; do
    if grep -q '^Actions=' "$HOST_DESKTOP"; then
      grep -q "^Actions=.*\b${act};" "$HOST_DESKTOP" || sed -i -e "s|^Actions=\(.*\)\$|Actions=\1${act};|" "$HOST_DESKTOP"
    else
      sed -i -e "0,/^\[Desktop Entry\]/s|^\[Desktop Entry\]|[Desktop Entry]\nActions=${act};|" "$HOST_DESKTOP"
    fi
  done
  printf '\n[Desktop Action Update]\nName=Check for updates\nExec=%s\n' "$update_exec" >> "$HOST_DESKTOP"
  printf '\n[Desktop Action Settings]\nName=Claude Desktop Settings\nExec=%s\n' "$settings_exec" >> "$HOST_DESKTOP"

  chmod +x "$HOST_DESKTOP" 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$(dirname "$HOST_DESKTOP")" 2>/dev/null || true

  # 4) Register the app's URL scheme(s) on the host so browser OAuth deep-links
  #    (e.g. claude://...) route back to the containerized app for sign-in.
  #    This is what makes network isolation compatible with logging in.
  if command -v xdg-mime >/dev/null 2>&1; then
    local schemes m
    schemes="$(grep -m1 '^MimeType=' "$HOST_DESKTOP" 2>/dev/null | cut -d= -f2- | tr ';' ' ')"
    for m in $schemes; do
      case "$m" in
        x-scheme-handler/*)
          xdg-mime default "$(basename "$HOST_DESKTOP")" "$m" 2>/dev/null \
            && log "Registered URL handler: $m" || true ;;
      esac
    done
  fi
}

remove_host_launcher() {
  rm -f "$HOST_BIN" "$HOST_DESKTOP" 2>/dev/null || true
  # Themed icons, by manifest — only ever the files this script wrote.
  if [[ -f "$ICON_MANIFEST" ]]; then
    local p
    while IFS= read -r p; do
      [[ -n "$p" && "$p" == "$HOST_ICON_DIR/hicolor/"* ]] && rm -f "$p"
    done < "$ICON_MANIFEST"
    rm -f "$ICON_MANIFEST"
    # Drop our theme cache if nothing else is left in the tree, then prune the
    # directories we created — any other theme content stays put.
    if [[ -z "$(find "$HOST_ICON_DIR/hicolor" -type f ! -name 'icon-theme.cache' -print -quit 2>/dev/null)" ]]; then
      rm -f "$HOST_ICON_DIR/hicolor/icon-theme.cache"
    fi
    find "$HOST_ICON_DIR/hicolor" -type d -empty -delete 2>/dev/null || true
  fi
  rm -f "$HOST_ICON_DIR"/claude-desktop.* 2>/dev/null || true   # pre-manifest installs
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q -f -t "$HOST_ICON_DIR/hicolor" 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$(dirname "$HOST_DESKTOP")" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Host folders visible inside the container
# ---------------------------------------------------------------------------
# Why this exists: the file picker, "Attach file" and drag-and-drop all hand
# the app *host* paths (a drop from Nautilus is a file:///home/you/Documents/x
# URI). With an isolated home those paths simply do not exist in the container,
# so imports and drops fail silently. Mounting the standard user folders at
# their real paths (read-only where possible) fixes that without exposing the
# rest of the home.
resolve_user_dirs() {
  USER_DIR_MOUNTS=()
  [[ $USER_DIRS -eq 1 && $ISOLATE_HOME -eq 1 ]] || return 0
  local key mode d
  for key in DOCUMENTS:ro DESKTOP:ro PICTURES:ro DOWNLOAD:rw; do
    mode="${key#*:}"; key="${key%%:*}"
    if command -v xdg-user-dir >/dev/null 2>&1; then
      d="$(xdg-user-dir "$key" 2>/dev/null || true)"
    else
      d=""
    fi
    if [[ -z "$d" ]]; then
      case "$key" in
        DOCUMENTS) d="$REAL_HOME/Documents" ;;
        DESKTOP)   d="$REAL_HOME/Desktop" ;;
        PICTURES)  d="$REAL_HOME/Pictures" ;;
        DOWNLOAD)  d="$REAL_HOME/Downloads" ;;
      esac
    fi
    d="$(readlink -f "$d" 2>/dev/null || true)"
    # xdg-user-dir falls back to $HOME itself for unset keys — never mount that.
    [[ -n "$d" && -d "$d" && "$d" != "$REAL_HOME" && "$d" != "$BOX_HOME" ]] || continue
    case " ${USER_DIR_MOUNTS[*]:-} " in *" $d:"*) continue ;; esac
    USER_DIR_MOUNTS+=("$d:$mode")
  done
}

# Make the shared folders easy to find from inside the app: a symlink of the
# same name in the dedicated home (the file picker opens there) and a GTK
# sidebar bookmark. Idempotent; never replaces a real directory the app made.
link_shared_dirs_into_box_home() {
  [[ $ISOLATE_HOME -eq 1 ]] || return 0
  local entry d name bm="$BOX_HOME/.config/gtk-3.0/bookmarks"
  mkdir -p "$(dirname "$bm")"; touch "$bm"
  for entry in "${USER_DIR_MOUNTS[@]:-}" "${SHARES[@]:-}"; do
    [[ -z "$entry" ]] && continue
    d="${entry%%:*}"; d="$(readlink -f "$d" 2>/dev/null || true)"
    [[ -n "$d" && -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -L "$BOX_HOME/$name" || ! -e "$BOX_HOME/$name" ]]; then
      ln -sfn "$d" "$BOX_HOME/$name"
    fi
    grep -qxF "file://$d" "$bm" 2>/dev/null || printf 'file://%s\n' "$d" >>"$bm"
  done
}

# Is every expected user folder actually mounted in the existing container?
# Containers made by pre-release builds lack them, and bind mounts cannot be
# added after creation — the fix is a one-off --recreate.
container_missing_user_dirs() {
  [[ $ISOLATE_HOME -eq 1 ]] || return 1
  resolve_user_dirs
  [[ ${#USER_DIR_MOUNTS[@]} -gt 0 ]] || return 1
  local dests m
  dests="$("$MGR" inspect "$NAME" --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null)" || return 1
  for m in "${USER_DIR_MOUNTS[@]}"; do
    grep -qxF "${m%%:*}" <<<"$dests" || return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
case "$ACTION" in
  recreate)
    # Bind mounts are fixed at `distrobox create`, so changing shares means a
    # fresh container. The dedicated home (login, chats) is untouched.
    if container_exists "$NAME"; then
      log "Stopping and removing container '$NAME' (your data in $BOX_HOME is kept) ..."
      distrobox rm --force "$NAME"
    else
      warn "No container named '$NAME'; performing a plain install."
    fi
    ACTION="install"
    ;&
  install)
    if container_exists "$NAME"; then
      log "Container '$NAME' already exists — reusing it."
    else
      # Assemble create args with the chosen isolation posture.
      declare -a CREATE=(create --name "$NAME" --image "$IMAGE" --yes)
      declare -a CREATE_ENV=()   # env overrides applied ONLY to `distrobox create`

      if [[ $ISOLATE_HOME -eq 1 ]]; then
        mkdir -p "$BOX_HOME"
        # distrobox ALWAYS bind-mounts $HOME (distrobox-create line ~734), and
        # the --home flag does NOT stop that — it only adds a second home and
        # flips $HOME. So we point HOME at the sandbox *for the create call
        # only*: distrobox then mounts the sandbox as the home and never mounts
        # the real one. XDG_* stay real so podman keeps using the real,
        # already-populated container storage (no image re-pull, no split state).
        CREATE_ENV=(env
          "HOME=$BOX_HOME"
          "XDG_DATA_HOME=$REAL_HOME/.local/share"
          "XDG_CONFIG_HOME=$REAL_HOME/.config"
          "XDG_CACHE_HOME=$REAL_HOME/.cache")
        log "Filesystem: ISOLATED — sandbox home $BOX_HOME; real \$HOME not mounted"
        log "            (reachable only via /run/host — a soft boundary, see --help)."
      else
        warn "Filesystem: FULL — the app will see your real \$HOME."
      fi

      if [[ $ISOLATE_NET -eq 1 ]]; then
        if distrobox_supports_netns; then
          CREATE+=(--unshare-netns)
          log "Network: ISOLATED — own namespace (outbound internet, no host localhost)."
        else
          warn "This distrobox lacks --unshare-netns; falling back to shared host network."
          ISOLATE_NET=0
        fi
      else
        warn "Network: SHARED — the app shares your host network namespace."
      fi

      # Standard user folders at their real paths (see resolve_user_dirs).
      resolve_user_dirs
      if [[ ${#USER_DIR_MOUNTS[@]} -gt 0 ]]; then
        for s in "${USER_DIR_MOUNTS[@]}"; do
          CREATE+=(--volume "${s%%:*}:${s%%:*}:${s##*:}")
          log "User folder: ${s%%:*} (${s##*:})"
        done
      elif [[ $ISOLATE_HOME -eq 1 ]]; then
        warn "No standard user folders exposed (--no-user-dirs): attaching files and"
        warn "drag-and-drop only work for files under $BOX_HOME or a --share dir."
      fi

      # Explicitly shared host directories.
      for s in "${SHARES[@]:-}"; do
        [[ -z "$s" ]] && continue
        s="$(readlink -f "$s")" || die "bad --share path: $s"
        [[ -d "$s" ]] || die "--share path is not a directory: $s"
        CREATE+=(--volume "$s:$s:rw")
        log "Sharing host dir: $s"
      done

      log "Creating Ubuntu container '$NAME' (image: $IMAGE) ..."
      "${CREATE_ENV[@]}" distrobox "${CREATE[@]}"
      link_shared_dirs_into_box_home
    fi

    log "Installing Claude inside the container."
    log "(First run also initializes the container — this can take a few minutes.)"
    distrobox enter --name "$NAME" -- bash -c "$(emit_install_inner)"

    log "Collecting launcher metadata from the container ..."
    collect_launcher_meta
    [[ -n "$CLAUDE_BIN" ]] || die "claude-desktop not found in the container after install."

    build_host_launcher

    echo
    log "Done! Search \"Claude\" in your application menu, or run: claude-desktop"
    [[ $SANDBOX -eq 1 ]] || warn "Launcher uses --no-sandbox (reliable in a rootless container)."
    if [[ $ISOLATE_NET -eq 1 ]]; then
      warn "Network is isolated. If sign-in fails (some OAuth flows use a localhost callback),"
      warn "re-run with --share-net after removing: $0 --remove && $0 --share-net"
    fi
    if [[ $ISOLATE_HOME -eq 1 ]]; then
      log "The app only sees $BOX_HOME, your standard folders (Documents/Desktop/"
      log "Pictures read-only, Downloads read-write) and any --share dirs. Change"
      log "that later with: $0 --recreate [--share <dir>] [--no-user-dirs]"
    fi
    log "Update later: $0 --update   |   Remove: $0 --remove"
    if have_gui; then
      msg="<b>Claude Desktop is installed.</b>\n\nSearch for <b>Claude</b> in your app menu to launch it, then sign in.\n\n"
      if [[ $ISOLATE_HOME -eq 1 ]]; then
        msg+="• The app only sees its own folder ($BOX_HOME)"
        [[ ${#SHARES[@]} -gt 0 ]] && msg+=" plus the folders you shared"
        msg+=" — your real home stays hidden.\n"
      fi
      [[ $ISOLATE_NET -eq 1 ]] && msg+="• It runs in its own network namespace (internet yes, your host's localhost no).\n"
      msg+="\nTo update later: right-click the Claude icon → <b>Check for updates</b>, or open <b>Claude Desktop Setup</b>."
      gui_info "$msg"
    fi
    ;;

  update)
    container_exists "$NAME" || die "No container named '$NAME'. Run without --update to install first."
    if [[ $FULL_UPGRADE -eq 1 ]]; then
      log "Updating Claude + base OS security patches inside container '$NAME' ..."
    else
      log "Updating Claude inside container '$NAME' ..."
    fi
    # tee to a real file, never /dev/stderr: under systemd fd 2 is a journald
    # socket, which cannot be reopened by path — tee dies at startup and the
    # in-container apt run is then killed by SIGPIPE mid-install.
    UPDATE_LOG="$(mktemp)"
    if ! distrobox enter --name "$NAME" -- env FULL_UPGRADE="$FULL_UPGRADE" bash -c "$(emit_update_inner)" | tee "$UPDATE_LOG"; then
      rm -f "$UPDATE_LOG"
      notify_user "Claude Desktop update failed" "See: journalctl --user -u ${TIMER_NAME}"
      die "The in-container update failed (see output above)."
    fi
    UPDATED="$(sed -n 's/^META:UPDATED=//p' "$UPDATE_LOG" | head -n1)"
    VER_BEFORE="$(sed -n 's/^META:VER_BEFORE=//p' "$UPDATE_LOG" | head -n1)"
    VER_AFTER="$(sed -n 's/^META:VER_AFTER=//p' "$UPDATE_LOG" | head -n1)"
    rm -f "$UPDATE_LOG"

    # Rebuild the host launcher while the container is still up, so a new
    # icon, name or window class from the package lands on the host too.
    if [[ "$UPDATED" == "1" ]]; then
      log "Refreshing the host launcher ..."
      collect_launcher_meta
      if [[ -n "$CLAUDE_BIN" ]]; then
        build_host_launcher
      else
        warn "Could not read launcher metadata; left the existing launcher alone."
      fi
    fi

    # The upgrade only replaces files on disk. If the app is still running it is
    # the OLD build (Electron stays resident and `distrobox enter` would just
    # refocus it), so it must be restarted for the update to take effect.
    RESTART_PENDING=0
    if [[ "$UPDATED" == "1" ]] && "$MGR" exec "$NAME" pgrep -f claude-desktop >/dev/null 2>&1; then
      reply=""
      if have_gui; then
        if gui_question "Claude was updated to <b>$VER_AFTER</b>, but the running window is still the old version.\n\nRestart Claude now? (Your data and login are kept — just relaunch it afterwards.)"; then
          reply="y"
        else
          reply="n"
        fi
      elif [[ -t 0 ]]; then
        read -r -p "Claude Desktop is still running the old version. Restart it now? [Y/n] " reply || reply=""
      else
        reply="n"; RESTART_PENDING=1
        warn "Update installed but Claude is running the OLD version — restart it to apply:"
        warn "  podman stop $NAME   (then relaunch Claude)"
      fi
      if [[ ! "$reply" =~ ^[Nn] ]]; then
        log "Stopping container '$NAME' (and the old app) ..."
        distrobox stop --yes "$NAME"
        log "Stopped. Relaunch Claude from your app menu or with: claude-desktop"
        if have_gui && gui_question "Claude has been stopped. Launch the new version now?"; then
          gtk-launch "$(basename "$HOST_DESKTOP")" >/dev/null 2>&1 \
            || nohup "$HOST_BIN" >/dev/null 2>&1 &
        fi
      elif [[ $RESTART_PENDING -eq 0 ]]; then
        RESTART_PENDING=1
        warn "Claude keeps running the OLD version until restarted (podman stop $NAME, then relaunch)."
      fi
    fi
    log "Update complete."

    if container_missing_user_dirs; then
      warn "This container was created by an older version of this tool: your Documents/"
      warn "Desktop/Pictures/Downloads folders are not mounted, so \"Attach file\" and"
      warn "drag-and-drop cannot work. Fix once (login and data are kept):"
      warn "  $0 --recreate"
      have_gui && gui_warn "Claude is updated, but this container was made by a pre-release build: your <b>Documents / Desktop / Pictures / Downloads</b> folders are not visible to it, so <b>Attach file</b> and <b>drag-and-drop</b> do not work.\n\nFix it once via <b>Rebuild the container</b> in this menu (login and data are kept)."
    fi

    if [[ "$UPDATED" == "1" ]]; then
      if [[ $RESTART_PENDING -eq 1 ]]; then
        notify_user "Claude Desktop updated: $VER_BEFORE → $VER_AFTER" "Restart Claude to start using the new version."
      else
        notify_user "Claude Desktop updated: $VER_BEFORE → $VER_AFTER" "The new version is ready."
      fi
      have_gui && [[ $RESTART_PENDING -eq 0 ]] && gui_info "Claude Desktop was updated: $VER_BEFORE → $VER_AFTER"
    else
      notify_user "Claude Desktop is up to date" "Version $VER_AFTER"
      have_gui && gui_info "Claude Desktop is already the newest version ($VER_AFTER)."
    fi
    ;;

  refresh-launcher)
    container_exists "$NAME" || die "No container named '$NAME'. Run without arguments to install first."
    log "Rebuilding the host launcher, desktop entry and icons ..."
    collect_launcher_meta
    [[ -n "$CLAUDE_BIN" ]] || die "claude-desktop not found in container '$NAME'."
    build_host_launcher
    log "Done. Log out and back in (or restart the shell) if the dock still shows the old icon."
    ;;

  remove)
    remove_timer
    remove_host_launcher
    if container_exists "$NAME"; then
      log "Removing container '$NAME' ..."
      distrobox rm --force "$NAME"
      log "Removed container '$NAME'."
    else
      warn "No container named '$NAME' to remove."
    fi
    if [[ $PURGE -eq 1 ]]; then
      log "Purging dedicated home: $BOX_HOME"
      rm -rf "$BOX_HOME"
    elif [[ -d "$BOX_HOME" ]]; then
      log "Left dedicated home in place: $BOX_HOME (delete with --purge or manually)."
    fi
    log "Host launcher removed."
    ;;

  gui-menu)
    # The "Claude Desktop Setup" window. Native GTK4/libadwaita when the
    # Python bindings are present (Fedora Workstation ships them); plain
    # zenity buttons otherwise. Either way the window only *picks* an action
    # token — every action re-invokes this script with the matching CLI flags
    # behind a progress dialog, so GUI and CLI share one code path. Loops
    # until closed.
    timer_enabled() { systemctl --user is-enabled "${TIMER_NAME}.timer" >/dev/null 2>&1; }
    have_gtk_menu() {
      python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")' 2>/dev/null
    }
    # gui_buttons TEXT BUTTON... : show TEXT with one button per argument,
    # stacked top-to-bottom in the order given; print the label that was
    # pressed. zenity stacks --extra-button entries bottom-up, so pass them
    # in reverse to get the listed order on screen.
    gui_buttons() {
      local text="$1"; shift
      local -a extra=()
      local i
      for ((i=$#; i>=1; i--)); do extra+=(--extra-button="${!i}"); done
      zenity --question --switch --width=520 --title="$GUI_TITLE" --icon=dialog-information \
             --text="$text" "${extra[@]}" 2>/dev/null || true
      # zenity exits 1 for every --extra-button press; the label on stdout is
      # what matters, so never let that status trip set -e.
    }
    # gtk_menu INSTALLED FREQ TOOLCHECK : native window. Prints one token:
    # update | self-check | repair | rebuild | remove | install |
    # install-share | close. Settings (schedule, tool check) apply in place
    # inside the window — only the zenity fallback still emits the
    # auto:<…> / toolcheck:<on|off> tokens for them.
    gtk_menu() {
      python3 - "$1" "$2" "$3" "$GUI_TITLE" "$SELF" "$NAME" <<'PYEOF'
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, Gio

installed = sys.argv[1] == "1"
freq = sys.argv[2]
toolcheck = sys.argv[3] == "1"
title = sys.argv[4]
selfpath = sys.argv[5]
boxname = sys.argv[6]
chosen = []


class Setup(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.claude_desktop_distrobox.Setup",
                         flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.freq = freq
        self.tool = toolcheck

    def pick(self, token):
        chosen.append(token)
        self.quit()

    def row(self, rtitle, subtitle, token):
        r = Adw.ActionRow(title=rtitle, activatable=True)
        if subtitle:
            r.set_subtitle(subtitle)
        r.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
        r.connect("activated", lambda *_: self.pick(token))
        return r

    # --- in-place settings -------------------------------------------
    # Schedule and tool-check changes run the (quick) systemd commands
    # directly and resync the widgets, so the window does not close and
    # reopen for a settings change. Heavy actions still exit with a token.
    def on_sched(self, btn, val):
        if btn.get_active() and val != self.freq:
            self.apply_timer(val, self.tool if val != "off" else False)

    def on_tool(self, row, *_):
        if row.get_active() != self.tool:
            self.apply_timer(self.freq, row.get_active())

    def apply_timer(self, new_freq, new_tool):
        if new_freq == "off":
            cmd = ["/bin/bash", selfpath, "--remove-timer"]
        else:
            cmd = ["/bin/bash", selfpath, "--install-timer",
                   "--every", new_freq, "--name", boxname]
            if new_tool:
                cmd.append("--tool-check")
        self.sched_box.set_sensitive(False)
        self.tsw.set_sensitive(False)
        try:
            proc = Gio.Subprocess.new(
                cmd,
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE)
        except Exception:
            self.finish_apply(False, new_freq, new_tool)
            return
        proc.wait_check_async(None, self.on_applied, (new_freq, new_tool))

    def on_applied(self, proc, res, data):
        try:
            ok = proc.wait_check_finish(res)
        except Exception:
            ok = False
        self.finish_apply(ok, *data)

    def finish_apply(self, ok, new_freq, new_tool):
        if ok:
            if new_freq != self.freq:
                msg = ("Auto-update turned off" if new_freq == "off"
                       else "Auto-update set to " + new_freq)
            else:
                msg = ("Tool-update check enabled" if new_tool
                       else "Tool-update check disabled")
            self.freq, self.tool = new_freq, new_tool
        else:
            msg = "Could not change the setting"
        # Resync every widget to the real state (reverts the click on failure).
        for b, _v, h in self.sched_btns:
            b.handler_block(h)
        for b, v, _h in self.sched_btns:
            b.set_active(v == self.freq)
        for b, _v, h in self.sched_btns:
            b.handler_unblock(h)
        self.tsw.handler_block(self.tsw_handler)
        self.tsw.set_active(self.tool)
        self.tsw.handler_unblock(self.tsw_handler)
        self.sched_box.set_sensitive(True)
        self.tsw.set_sensitive(self.freq != "off")
        self.overlay.add_toast(Adw.Toast(title=msg))

    def do_activate(self):
        # A plain box (no internal scroller) in a non-resizable window: the
        # window always hugs the content's natural height, growing when
        # "Advanced" expands and shrinking back when it collapses.
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24,
                       width_request=450,
                       margin_top=18, margin_bottom=6,
                       margin_start=16, margin_end=16)
        if installed:
            g = Adw.PreferencesGroup(description="Claude Desktop is installed.")
            g.add(self.row("Update now",
                           "Update the app and the container's security patches", "update"))
            g.add(self.row("Check for tool update",
                           "Ask GitHub once for a newer setup tool — it never checks in the background",
                           "self-check"))
            page.append(g)

            ga = Adw.PreferencesGroup(
                title="Auto-update",
                description="Keeps Claude and the container's security patches current in the "
                            "background; you get a notification when a new version lands.")
            sched = Adw.ActionRow(title="Schedule")
            box = Gtk.Box(valign=Gtk.Align.CENTER)
            box.add_css_class("linked")
            self.sched_box = box
            self.sched_btns = []
            lead = None
            for lbl, val in (("Off", "off"), ("Daily", "daily"),
                             ("Weekly", "weekly"), ("Monthly", "monthly")):
                b = Gtk.ToggleButton(label=lbl)
                if lead is None:
                    lead = b
                else:
                    b.set_group(lead)
                b.set_active(val == self.freq)
                h = b.connect("toggled", self.on_sched, val)
                self.sched_btns.append((b, val, h))
                box.append(b)
            sched.add_suffix(box)
            ga.add(sched)
            tsw = Adw.SwitchRow(
                title="Also check for setup-tool updates",
                subtitle="Asks GitHub on the same schedule and notifies you — "
                         "nothing installs by itself",
                active=self.tool,
                sensitive=(self.freq != "off"))
            self.tsw = tsw
            self.tsw_handler = tsw.connect("notify::active", self.on_tool)
            ga.add(tsw)
            page.append(ga)

            gadv = Adw.PreferencesGroup(title="Advanced")
            exp = Adw.ExpanderRow(title="Maintenance and removal",
                                  subtitle="Repair, rebuild or remove")
            exp.add_row(self.row("Repair app-menu entry",
                                 "Rebuild the launcher and its icon", "repair"))
            exp.add_row(self.row("Rebuild container",
                                 "Re-create the container with current settings — login and chats are kept",
                                 "rebuild"))
            exp.add_row(self.row("Remove Claude Desktop",
                                 "Delete the container, app-menu entry and update timer", "remove"))
            gadv.add(exp)
            page.append(gadv)
        else:
            g = Adw.PreferencesGroup(
                description="Claude Desktop is not installed yet. Install Anthropic's official, "
                            "signed app in a privacy-hardened container: your real home stays "
                            "hidden; the app gets its own private folder and network. First run "
                            "downloads a few hundred MB.")
            g.add(self.row("Install", "Privacy-hardened (recommended)", "install"))
            g.add(self.row("Install and share one folder",
                           "Lets Claude (Cowork / Code) work on a folder you pick", "install-share"))
            g.add(self.row("Check for tool update",
                           "Ask GitHub once for a newer setup tool", "self-check"))
            page.append(g)

        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        tv.set_content(Adw.Clamp(child=page, maximum_size=560))
        close = Gtk.Button(label="Close", halign=Gtk.Align.END,
                           margin_top=6, margin_bottom=10, margin_end=14)
        close.connect("clicked", lambda *_: self.quit())
        tv.add_bottom_bar(close)

        self.overlay = Adw.ToastOverlay(child=tv)
        win = Adw.ApplicationWindow(application=self, title=title,
                                    resizable=False)
        win.set_content(self.overlay)
        win.present()


Setup().run([sys.argv[0]])
print(chosen[0] if chosen else "close")
PYEOF
    }
    # zenity_menu INSTALLED FREQ TOOLCHECK : same tokens via zenity buttons.
    zenity_menu() {
      local installed="$1" freq="$2" tool="$3" choice sel adv o
      if [[ "$installed" == 1 ]]; then
        local -a au_btns=() tc_btn=()
        for o in Off Daily Weekly Monthly; do
          if [[ "${o,,}" == "$freq" ]]; then au_btns+=("Auto-update: $o ✔"); else au_btns+=("Auto-update: $o"); fi
        done
        if [[ "$freq" != "off" ]]; then
          if [[ "$tool" -eq 1 ]]; then tc_btn=("Scheduled tool check: On ✔"); else tc_btn=("Scheduled tool check: Off"); fi
        fi
        choice="$(gui_buttons "Claude Desktop is <b>installed</b>.\n\nAuto-update keeps Claude and the container's security patches current in the background — click the schedule you want (✔ marks the current one)." \
                    "Update now" "Check for tool update" "${au_btns[@]}" "${tc_btn[@]}" "Advanced…" "Close")"
      else
        choice="$(gui_buttons "Claude Desktop is <b>not installed</b> yet.\n\nInstall Anthropic's official, signed app in a privacy-hardened container. Your real home stays hidden; the app gets its own private folder and network. First run downloads a few hundred MB." \
                    "Install…" "Install and share one folder…" "Check for tool update" "Close")"
      fi
      case "$choice" in
        "Update now")            echo update ;;
        "Check for tool update") echo self-check ;;
        "Auto-update: "*)        sel="${choice#Auto-update: }"; sel="${sel%% ✔}"; echo "auto:${sel,,}" ;;
        "Scheduled tool check: On ✔") echo toolcheck:off ;;
        "Scheduled tool check: Off")  echo toolcheck:on ;;
        "Install…")              echo install ;;
        "Install and share one folder…") echo install-share ;;
        "Advanced…")
          adv="$(gui_buttons "Maintenance and removal." \
                   "Repair app-menu entry" "Rebuild container" "Remove Claude Desktop…" "Back")"
          case "$adv" in
            "Repair app-menu entry")   echo repair ;;
            "Rebuild container")       echo rebuild ;;
            "Remove Claude Desktop…")  echo remove ;;
            *)                         echo again ;;
          esac
          ;;
        *) echo close ;;
      esac
    }
    while :; do
      installed=0; container_exists "$NAME" && installed=1
      freq="off"
      [[ $installed -eq 1 ]] && timer_enabled && freq="$(timer_frequency)"
      tool=0
      [[ "$freq" != "off" ]] && timer_tool_check && tool=1
      choice=""
      if have_gtk_menu; then
        choice="$(gtk_menu "$installed" "$freq" "$tool")" || choice=""
      fi
      [[ -z "$choice" ]] && choice="$(zenity_menu "$installed" "$freq" "$tool")"
      case "$choice" in
        install|install-share)
          share=(); dir=""
          if [[ "$choice" == "install-share" ]]; then
            dir="$(zenity --file-selection --directory --title="Choose a folder to share with Claude" 2>/dev/null)" || continue
            share=(--share "$dir")
          fi
          gui_question "This will:\n\n• install <b>distrobox</b>/<b>podman</b> if missing (asks for your password)\n• create an Ubuntu container and install Anthropic's <b>official, signed</b> Claude app in it\n• add <b>Claude</b> to your app menu${dir:+\n• let the app access <b>$dir</b>}\n\nContinue?" || continue
          run_with_progress "Installing Claude Desktop… (a few minutes on first run)" --install "${share[@]}" || continue
          ;;
        update)
          run_with_progress "Updating Claude Desktop…" --update --full || continue
          ;;
        auto:*)
          sel="${choice#auto:}"
          [[ "$sel" == "$freq" ]] && continue   # picked the current schedule
          if [[ "$sel" == "off" ]]; then
            run_with_progress "Turning auto-update off…" --remove-timer
          else
            tflags=(); [[ $tool -eq 1 ]] && tflags=(--tool-check)   # keep the switch as it was
            run_with_progress "Setting auto-update to ${sel}…" --install-timer --every "$sel" "${tflags[@]}"
          fi
          ;;
        toolcheck:*)
          [[ "$freq" == "off" ]] && continue   # only meaningful with a schedule
          if [[ "$choice" == "toolcheck:on" ]]; then
            run_with_progress "Enabling the scheduled tool-update check…" --install-timer --every "$freq" --tool-check
          else
            run_with_progress "Disabling the scheduled tool-update check…" --install-timer --every "$freq"
          fi
          ;;
        self-check)
          "$SELF" --check-self-update --gui || true
          ;;
        repair)
          run_with_progress "Rebuilding the app-menu entry…" --refresh-launcher && \
            gui_info "Done. Log out and back in if the dock still shows the old icon."
          ;;
        rebuild)
          gui_question "Rebuild the Claude container?\n\nThe app is closed and its container re-created with the current settings, so your <b>Documents, Desktop, Pictures</b> (read-only) and <b>Downloads</b> folders become visible to it — that is what makes <b>Attach file</b> and <b>drag-and-drop</b> work.\n\nYour login and chats are <b>kept</b>. Takes a few minutes." || continue
          run_with_progress "Rebuilding the Claude container…" --recreate && \
            gui_info "Done. Launch Claude again — attaching files and dropping them onto the window now work."
          ;;
        remove)
          gui_question "Remove Claude Desktop?\n\nThis deletes the container, the app-menu entry and the auto-update timer.\nYour login and chat data (in $BOX_HOME) are <b>kept</b> unless you choose to delete them next." || continue
          purge=()
          if zenity --question --width=460 --title="$GUI_TITLE" --icon=dialog-warning \
               --text="Also delete your Claude login and local data?\n\n<b>$BOX_HOME</b>\n\nThis cannot be undone." \
               --ok-label="Delete data too" --cancel-label="Keep data" 2>/dev/null; then
            purge=(--purge)
          fi
          run_with_progress "Removing Claude Desktop…" --remove "${purge[@]}" && \
            gui_info "Claude Desktop has been removed."
          ;;
        again) : ;;
        *) exit 0 ;;
      esac
    done
    ;;
  *)
    die "internal error: unknown action '$ACTION'"
    ;;
esac

exit 0
