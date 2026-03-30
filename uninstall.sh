#!/bin/bash
set -euo pipefail

INSTALL_DIR=""
DEFAULT_INSTALL_DIR="/opt/wsl-disk-optimizer"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

log_info() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

log_ok() {
  printf "%b[ OK ]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

log_warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

log_err() {
  printf "%b[ERR ]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Uninstall WSL disk space optimization components.

Options:
  --install-dir DIR   Installation directory to remove
                      (default: read from marker, or /opt/wsl-disk-optimizer)
  --help              Show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      shift
      [[ $# -gt 0 ]] || { log_err "Missing value for --install-dir"; exit 1; }
      INSTALL_DIR="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      log_err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  log_err "Run with sudo"
  exit 1
fi

if [[ -z "$INSTALL_DIR" ]]; then
  MARKER="$DEFAULT_INSTALL_DIR/.install-marker"
  if [[ -f "$MARKER" ]]; then
    INSTALL_DIR="$(cat "$MARKER")"
    log_info "Read install dir from marker: $INSTALL_DIR"
  else
    INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    log_warn "Marker not found; using default: $INSTALL_DIR"
  fi
fi

TARGET_HOME="$HOME"
TARGET_USER="$(id -un)"
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
  if [[ -n "$SUDO_HOME" ]]; then
    TARGET_HOME="$SUDO_HOME"
    TARGET_USER="$SUDO_USER"
  fi
fi

removed_items=()

# ── Stop and disable all services/timers ──────────────────────────────
UNITS=(
  docker-gc.service
  docker-weekly-prune.timer
  docker-weekly-prune.service
  cache-cleanup.timer
  cache-cleanup.service
  wsl-mem-cleanup.timer
  wsl-mem-cleanup.service
  zsh-history-cleanup.timer
  zsh-history-cleanup.service
  wsl-heartbeat.service
)

log_info "Stopping services and timers"
systemctl stop "${UNITS[@]}" 2>/dev/null || true

log_info "Disabling services and timers"
systemctl disable "${UNITS[@]}" 2>/dev/null || true

log_ok "Services stopped and disabled"
removed_items+=("Systemd services stopped and disabled")

# ── Remove unit files ─────────────────────────────────────────────────
log_info "Removing systemd unit files"
for unit in "${UNITS[@]}"; do
  unit_path="/etc/systemd/system/$unit"
  if [[ -f "$unit_path" ]]; then
    rm -f "$unit_path"
    log_ok "Removed $unit_path"
  fi
done
removed_items+=("Systemd unit files from /etc/systemd/system/")

# ── Remove journald drop-in ──────────────────────────────────────────
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/wsl-disk-optimizer.conf"
if [[ -f "$JOURNALD_DROPIN" ]]; then
  rm -f "$JOURNALD_DROPIN"
  log_ok "Removed journald drop-in: $JOURNALD_DROPIN"
  removed_items+=("Journald drop-in configuration")

  JOURNALD_DIR="/etc/systemd/journald.conf.d"
  if [[ -d "$JOURNALD_DIR" ]] && [[ -z "$(ls -A "$JOURNALD_DIR")" ]]; then
    rmdir "$JOURNALD_DIR"
    log_ok "Removed empty directory: $JOURNALD_DIR"
  fi

  systemctl restart systemd-journald 2>/dev/null || true
  log_ok "Restarted systemd-journald"
else
  log_info "Journald drop-in not found; skipping"
fi

# ── Reload systemd ───────────────────────────────────────────────────
systemctl daemon-reload
log_ok "systemd daemon reloaded"

# ── Remove shell source lines ────────────────────────────────────────
log_info "Cleaning shell rc files for user $TARGET_USER"

for rc_file in "$TARGET_HOME/.bashrc" "$TARGET_HOME/.zshrc"; do
  if [[ -f "$rc_file" ]]; then
    escaped_dir="$(printf '%s' "$INSTALL_DIR" | sed 's/[\/&]/\\&/g')"
    if grep -qF "source $INSTALL_DIR/shell/dcdown" "$rc_file"; then
      sed -i "\|source $escaped_dir/shell/dcdown|d" "$rc_file"
      log_ok "Removed source line from $rc_file"
      removed_items+=("Source line from $rc_file")
    else
      log_info "No source line found in $rc_file"
    fi
  fi
done

# ── Remove install directory ─────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  log_ok "Removed install directory: $INSTALL_DIR"
  removed_items+=("Install directory: $INSTALL_DIR")
else
  log_info "Install directory not found: $INSTALL_DIR"
fi

# ── Windows uninstall instructions ───────────────────────────────────
echo ""
printf "%b%s%b\n" "$COLOR_YELLOW" "To complete uninstall, run in elevated PowerShell:" "$COLOR_RESET"
echo '  Unregister-ScheduledTask -TaskName "WSL-Disk-Optimizer" -Confirm:$false'
echo '  Remove-Item -Recurse "$env:ProgramData\wsl-disk-optimizer"'
echo ""

# ── Summary ──────────────────────────────────────────────────────────
printf "\nUninstall summary\n"
printf "%b──────────────────────────────────────%b\n" "$COLOR_BLUE" "$COLOR_RESET"
for item in "${removed_items[@]}"; do
  printf "  %b✓%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$item"
done
echo ""

log_ok "Uninstall complete"
