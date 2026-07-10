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
BOX_HOME="$HOME/.local/share/claude-desktop-box"   # dedicated container home
REAL_HOME="$HOME"              # the real host home (never mounted when isolating)
declare -a SHARES=()           # extra host dirs to expose (repeatable --share)

# Anthropic's signing-key fingerprint, from the official docs
# (https://code.claude.com/docs/en/desktop-linux).
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
die()  { printf '%serror:%s %s\n'   "$C_RED"  "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Run the official Claude desktop app on Fedora via distrobox (privacy-hardened).

Usage:
  install-claude-desktop-distrobox.sh [action] [options]

Actions:
  (default)        Create the container and install Claude + host launcher.
  --update         Update Claude inside the existing container.
                   Add --full to also apt-upgrade the container's base OS.
  --remove         Remove the container, the host launcher, and the timer.
  --install-timer  Enable a weekly systemd *user* timer that auto-updates
                   Claude + the container's base OS (runs --update --full).
  --remove-timer   Disable and remove that timer.

Privacy options (defaults are the hardened choices):
  --isolate-home   Give the container a dedicated home dir (default).
  --full-home      Opt out: mount your real $HOME into the container.
  --isolate-net    Give the container its own network namespace (default).
  --share-net      Opt out: share the host network namespace.
  --share <dir>    Expose a host directory to the app (repeatable). Use this to
                   let Cowork/Code work on specific project folders while the
                   rest of your home stays hidden.
  --box-home <dir> Where the dedicated home lives (default:
                   ~/.local/share/claude-desktop-box).

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
export DEBIAN_FRONTEND=noninteractive
EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

echo "==> [container] Installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg

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
sudo apt-get update -y
sudo apt-get install -y claude-desktop
echo "==> [container] Install complete."
INNER
}

emit_update_inner() {
  cat <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "==> [container] Updating claude-desktop..."
sudo apt-get update -y
sudo apt-get install -y --only-upgrade claude-desktop
if [ "${FULL_UPGRADE:-0}" = "1" ]; then
  echo "==> [container] Applying base OS security patches (apt upgrade)..."
  sudo apt-get upgrade -y
  sudo apt-get autoremove -y --purge
  sudo apt-get clean
fi
echo "==> [container] Update complete."
INNER
}

# Prints machine-readable facts about the installed app (binary, .desktop, icon).
emit_meta_inner() {
  cat <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
bin_path="$(command -v claude-desktop || true)"
desktop_src="$(find /usr/share/applications -maxdepth 1 -iname '*claude*.desktop' 2>/dev/null | head -n1 || true)"
icon_name=""
[ -n "$desktop_src" ] && icon_name="$(grep -m1 '^Icon=' "$desktop_src" | cut -d= -f2- || true)"
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
INNER
}

# ---------------------------------------------------------------------------
# Auto-update timer (optional): a systemd *user* timer that runs
# `--update --full` weekly. Units are generated with this script's own
# absolute path, so they keep working wherever the repo lives.
# ---------------------------------------------------------------------------
TIMER_NAME="claude-desktop-update"
install_timer() {
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found — this needs a systemd user session."
  local self unitdir
  self="$(readlink -f "$0")"
  unitdir="$HOME/.config/systemd/user"
  mkdir -p "$unitdir"
  cat > "$unitdir/${TIMER_NAME}.service" <<EOF
[Unit]
Description=Update Claude Desktop (distrobox) + container base OS security patches
Documentation=file://$self

[Service]
Type=oneshot
ExecStart=/bin/bash $self --update --full --name $NAME
TimeoutStartSec=1800
EOF
  cat > "$unitdir/${TIMER_NAME}.timer" <<EOF
[Unit]
Description=Weekly Claude Desktop update (distrobox) + base OS patches

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${TIMER_NAME}.timer"
  log "Auto-update timer installed and enabled (weekly)."
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
    --update)         ACTION="update"; shift ;;
    --remove)         ACTION="remove"; shift ;;
    --install-timer)  ACTION="install-timer"; shift ;;
    --remove-timer)   ACTION="remove-timer"; shift ;;
    --print-inner)    ACTION="print-inner"; shift ;;
    --sandbox)      SANDBOX=1; shift ;;
    --isolate-home) ISOLATE_HOME=1; shift ;;
    --full-home)    ISOLATE_HOME=0; shift ;;
    --isolate-net)  ISOLATE_NET=1; shift ;;
    --share-net)    ISOLATE_NET=0; shift ;;
    --full)         FULL_UPGRADE=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --share)        SHARES+=("${2:?--share requires a directory}"); shift 2 ;;
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

# Timer management is host-side (systemd) only — no container needed.
if [[ "$ACTION" == "install-timer" ]]; then install_timer; exit 0; fi
if [[ "$ACTION" == "remove-timer" ]]; then remove_timer; exit 0; fi

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
  log "Installing $pkg (needs sudo) ..."
  sudo dnf install -y "$pkg"
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
# Host-side launcher (works with an isolated home, unlike distrobox-export)
# ---------------------------------------------------------------------------
build_host_launcher() {
  local claude_bin="$1" desktop_src="$2" icon_file="$3"
  local flags=""
  [[ $SANDBOX -eq 1 ]] || flags="--no-sandbox"

  mkdir -p "$(dirname "$HOST_BIN")" "$(dirname "$HOST_DESKTOP")" "$HOST_ICON_DIR"

  # 1) Wrapper on PATH. Use the ABSOLUTE in-container binary path (not the bare
  #    name) so it can never resolve back to this very wrapper through a shared
  #    PATH entry, and force HOME to the sandbox so the app writes there.
  local runcmd
  if [[ $ISOLATE_HOME -eq 1 ]]; then
    runcmd="$(printf 'env HOME=%q %q %s' "$BOX_HOME" "$claude_bin" "$flags")"
  else
    runcmd="$(printf '%q %s' "$claude_bin" "$flags")"
  fi
  log "Writing launcher: $HOST_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Auto-generated by install-claude-desktop-distrobox.sh\n'
    printf '# Launches Claude Desktop inside the "%s" distrobox container.\n' "$NAME"
    printf 'exec distrobox enter --name %q -- %s "$@"\n' "$NAME" "$runcmd"
  } > "$HOST_BIN"
  chmod +x "$HOST_BIN"

  # 2) Copy the app icon out of the container (podman cp is mount-independent).
  local host_icon=""
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

  # 3) Host .desktop: start from the app's own file (keeps Name/MimeType/
  #    StartupWMClass) and rewrite Exec/Icon to point at our wrapper.
  log "Writing desktop entry: $HOST_DESKTOP"
  local tmp; tmp="$(mktemp)"
  if [[ -n "$desktop_src" ]] && "$MGR" cp "$NAME:$desktop_src" "$tmp" 2>/dev/null; then
    sed -i \
      -e "s|^Exec=.*|Exec=${HOST_BIN} %U|" \
      -e '/^DBusActivatable=/d' \
      -e '/^TryExec=/d' \
      "$tmp"
    if [[ -n "$host_icon" ]]; then
      sed -i -e "s|^Icon=.*|Icon=${host_icon}|" "$tmp"
    fi
    cp "$tmp" "$HOST_DESKTOP"
  else
    # Fallback: synthesize a minimal entry.
    {
      printf '[Desktop Entry]\nType=Application\nName=Claude\n'
      printf 'Exec=%s %%U\n' "$HOST_BIN"
      [[ -n "$host_icon" ]] && printf 'Icon=%s\n' "$host_icon"
      printf 'Terminal=false\nCategories=Utility;Network;\n'
    } > "$HOST_DESKTOP"
  fi
  rm -f "$tmp"
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
  rm -f "$HOST_ICON_DIR"/claude-desktop.* 2>/dev/null || true
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$(dirname "$HOST_DESKTOP")" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
case "$ACTION" in
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
    fi

    log "Installing Claude inside the container."
    log "(First run also initializes the container — this can take a few minutes.)"
    distrobox enter --name "$NAME" -- bash -c "$(emit_install_inner)"

    log "Collecting launcher metadata from the container ..."
    META_OUT="$(distrobox enter --name "$NAME" -- bash -c "$(emit_meta_inner)" 2>/dev/null || true)"
    CLAUDE_BIN="$(printf '%s\n' "$META_OUT" | sed -n 's/^META:CLAUDE_BIN=//p'         | head -n1)"
    DESKTOP_SRC="$(printf '%s\n' "$META_OUT" | sed -n 's/^META:CLAUDE_DESKTOP_SRC=//p' | head -n1)"
    ICON_FILE="$(printf '%s\n' "$META_OUT"  | sed -n 's/^META:CLAUDE_ICON_FILE=//p'   | head -n1)"
    [[ -n "$CLAUDE_BIN" ]] || die "claude-desktop not found in the container after install."

    build_host_launcher "$CLAUDE_BIN" "$DESKTOP_SRC" "$ICON_FILE"

    echo
    log "Done! Search \"Claude\" in your application menu, or run: claude-desktop"
    [[ $SANDBOX -eq 1 ]] || warn "Launcher uses --no-sandbox (reliable in a rootless container)."
    if [[ $ISOLATE_NET -eq 1 ]]; then
      warn "Network is isolated. If sign-in fails (some OAuth flows use a localhost callback),"
      warn "re-run with --share-net after removing: $0 --remove && $0 --share-net"
    fi
    if [[ $ISOLATE_HOME -eq 1 ]]; then
      log "The app only sees $BOX_HOME plus any --share dirs. Add folders later by"
      log "re-creating with more --share flags, or bind-mount into the container."
    fi
    log "Update later: $0 --update   |   Remove: $0 --remove"
    ;;

  update)
    container_exists "$NAME" || die "No container named '$NAME'. Run without --update to install first."
    if [[ $FULL_UPGRADE -eq 1 ]]; then
      log "Updating Claude + base OS security patches inside container '$NAME' ..."
    else
      log "Updating Claude inside container '$NAME' ..."
    fi
    distrobox enter --name "$NAME" -- env FULL_UPGRADE="$FULL_UPGRADE" bash -c "$(emit_update_inner)"
    log "Update complete."
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

  *)
    die "internal error: unknown action '$ACTION'"
    ;;
esac
