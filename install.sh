#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/wsl-disk-optimizer"
PORT="19999"

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

Install WSL disk space optimization components.

Options:
  --all               Install all components (default)
  --docker            Install Docker cleanup components only
  --wsl               Install WSL maintenance components only
  --watcher           Install TCP watcher components only
  --shell             Install shell aliases only
  --no-docker         Exclude Docker components from --all
  --no-wsl            Exclude WSL components from --all
  --no-watcher        Exclude watcher components from --all
  --no-shell          Exclude shell components from --all
  --install-dir DIR   Installation directory (default: /opt/wsl-disk-optimizer)
  --port PORT         Heartbeat port for watcher (default: 19999)
  --help              Show this help and exit
EOF
}

install_unit() {
  local src="$1"
  local dst="$2"
  local use_port_replace="$3"

  if [[ "$use_port_replace" == "yes" ]]; then
    sed "s|__INSTALL_DIR__|$INSTALL_DIR|g; s|__HOME__|$TARGET_HOME|g; s|^Environment=WSL_HEARTBEAT_PORT=.*$|Environment=WSL_HEARTBEAT_PORT=$PORT|g" "$src" > "$dst"
  else
    sed "s|__INSTALL_DIR__|$INSTALL_DIR|g; s|__HOME__|$TARGET_HOME|g" "$src" > "$dst"
  fi
}

append_source_line() {
  local rc_file="$1"
  local source_line="$2"

  if [[ ! -f "$rc_file" ]]; then
    return
  fi

  if grep -qF "$source_line" "$rc_file"; then
    log_info "Already present in $rc_file: $source_line"
    return
  fi

  printf "\n%s\n" "$source_line" >> "$rc_file"
  log_ok "Added source line to $rc_file"
}

flag_all=false
flag_docker=false
flag_wsl=false
flag_watcher=false
flag_shell=false
no_docker=false
no_wsl=false
no_watcher=false
no_shell=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      flag_all=true
      ;;
    --docker)
      flag_docker=true
      ;;
    --wsl)
      flag_wsl=true
      ;;
    --watcher)
      flag_watcher=true
      ;;
    --shell)
      flag_shell=true
      ;;
    --no-docker)
      no_docker=true
      ;;
    --no-wsl)
      no_wsl=true
      ;;
    --no-watcher)
      no_watcher=true
      ;;
    --no-shell)
      no_shell=true
      ;;
    --install-dir)
      shift
      [[ $# -gt 0 ]] || { log_err "Missing value for --install-dir"; exit 1; }
      INSTALL_DIR="$1"
      ;;
    --port)
      shift
      [[ $# -gt 0 ]] || { log_err "Missing value for --port"; exit 1; }
      PORT="$1"
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

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
  log_err "Invalid --port value: $PORT (expected 1-65535)"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  log_err "Run with sudo"
  exit 1
fi

if ! uname -r | grep -qi microsoft; then
  log_err "This tool requires WSL2"
  exit 1
fi

if ! systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
  log_err "Enable systemd in /etc/wsl.conf"
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  log_err "bash is required but not found"
  exit 1
fi

has_positive=false
for value in "$flag_all" "$flag_docker" "$flag_wsl" "$flag_watcher" "$flag_shell"; do
  if [[ "$value" == true ]]; then
    has_positive=true
    break
  fi
done

if [[ "$has_positive" == false ]]; then
  flag_all=true
fi

if [[ "$flag_all" == true ]]; then
  install_docker=true
  install_wsl=true
  install_watcher=true
  install_shell=true
else
  install_docker="$flag_docker"
  install_wsl="$flag_wsl"
  install_watcher="$flag_watcher"
  install_shell="$flag_shell"
fi

if [[ "$no_docker" == true ]]; then
  install_docker=false
fi
if [[ "$no_wsl" == true ]]; then
  install_wsl=false
fi
if [[ "$no_watcher" == true ]]; then
  install_watcher=false
fi
if [[ "$no_shell" == true ]]; then
  install_shell=false
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

docker_status="skipped"
wsl_status="skipped"
watcher_status="skipped"
shell_status="skipped"
docker_detail="Not selected"
wsl_detail="Not selected"
watcher_detail="Not selected"
shell_detail="Not selected"

if [[ "$install_docker" == true ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker not found; skipping Docker components"
    install_docker=false
    docker_detail="Docker CLI missing"
  elif ! docker info >/dev/null 2>&1; then
    log_warn "Docker daemon unavailable; skipping Docker components"
    install_docker=false
    docker_detail="Docker daemon unavailable"
  fi
fi

log_info "Creating install directories under $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/shell"

log_info "Copying Linux scripts"
cp -f "$SCRIPT_DIR"/linux/scripts/* "$INSTALL_DIR/scripts/"
chmod +x "$INSTALL_DIR"/scripts/*
log_ok "Installed scripts to $INSTALL_DIR/scripts"

log_info "Copying shell alias files"
cp -f "$SCRIPT_DIR"/linux/shell/* "$INSTALL_DIR/shell/"
log_ok "Installed shell files to $INSTALL_DIR/shell"

if [[ "$install_docker" == true ]]; then
  install_unit "$SCRIPT_DIR/linux/systemd/docker-gc.service" "/etc/systemd/system/docker-gc.service" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/docker-weekly-prune.service" "/etc/systemd/system/docker-weekly-prune.service" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/docker-weekly-prune.timer" "/etc/systemd/system/docker-weekly-prune.timer" "no"
fi

if [[ "$install_wsl" == true ]]; then
  install_unit "$SCRIPT_DIR/linux/systemd/cache-cleanup.service" "/etc/systemd/system/cache-cleanup.service" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/cache-cleanup.timer" "/etc/systemd/system/cache-cleanup.timer" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/wsl-mem-cleanup.service" "/etc/systemd/system/wsl-mem-cleanup.service" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/wsl-mem-cleanup.timer" "/etc/systemd/system/wsl-mem-cleanup.timer" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/zsh-history-cleanup.service" "/etc/systemd/system/zsh-history-cleanup.service" "no"
  install_unit "$SCRIPT_DIR/linux/systemd/zsh-history-cleanup.timer" "/etc/systemd/system/zsh-history-cleanup.timer" "no"
fi

if [[ "$install_watcher" == true ]]; then
  install_unit "$SCRIPT_DIR/linux/systemd/wsl-heartbeat.service" "/etc/systemd/system/wsl-heartbeat.service" "yes"
fi

systemctl daemon-reload
log_ok "systemd daemon reloaded"

if [[ "$install_docker" == true ]]; then
  systemctl enable --now docker-gc.service
  systemctl enable docker-weekly-prune.timer
  docker_status="installed"
  docker_detail="docker-gc.service + docker-weekly-prune.timer"
  log_ok "Docker services installed"
fi

if [[ "$install_wsl" == true ]]; then
  systemctl enable cache-cleanup.timer
  systemctl enable wsl-mem-cleanup.timer
  systemctl enable zsh-history-cleanup.timer

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/wsl-disk-optimizer.conf <<EOF
[Journal]
SystemMaxUse=200M
EOF
  systemctl restart systemd-journald

  wsl_status="installed"
  wsl_detail="maintenance timers + journald drop-in"
  log_ok "WSL maintenance timers installed"
fi

if [[ "$install_watcher" == true ]]; then
  systemctl enable --now wsl-heartbeat.service

  WIN_USER="$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$WIN_USER" ]]; then
    log_warn "Could not detect Windows user; watcher Windows setup skipped"
    watcher_status="partial"
    watcher_detail="Linux watcher installed; Windows user detection failed"
  else
    WIN_DIR="/mnt/c/Users/$WIN_USER/wsl-disk-optimizer"
    mkdir -p "$WIN_DIR"
    cp -f "$SCRIPT_DIR"/windows/* "$WIN_DIR/"
    WIN_PS_PATH="$(wslpath -w "$WIN_DIR/setup-watcher.ps1" 2>/dev/null || echo "$WIN_DIR/setup-watcher.ps1" | sed 's|^/mnt/\([a-z]\)/|\U\1:/|; s|/|\\|g')"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS_PATH"
    watcher_status="installed"
    watcher_detail="heartbeat service + Windows scheduled task setup"
  fi
  log_ok "Watcher components processed"
fi

if [[ "$install_shell" == true ]]; then
  append_source_line "$TARGET_HOME/.zshrc" "source $INSTALL_DIR/shell/dcdown.zsh"
  append_source_line "$TARGET_HOME/.bashrc" "source $INSTALL_DIR/shell/dcdown.bash"
  shell_status="installed"
  shell_detail="source lines added for $TARGET_USER"
fi

if [[ "$install_docker" == false && "$docker_detail" == "Not selected" ]]; then
  docker_detail="Disabled by flags"
fi
if [[ "$install_wsl" == false && "$wsl_detail" == "Not selected" ]]; then
  wsl_detail="Disabled by flags"
fi
if [[ "$install_watcher" == false && "$watcher_detail" == "Not selected" ]]; then
  watcher_detail="Disabled by flags"
fi
if [[ "$install_shell" == false && "$shell_detail" == "Not selected" ]]; then
  shell_detail="Disabled by flags"
fi

echo "$INSTALL_DIR" > "$INSTALL_DIR/.install-marker"
log_ok "Wrote install marker: $INSTALL_DIR/.install-marker"

printf "\nInstallation summary\n"
printf "%-12s %-10s %s\n" "Component" "Status" "Details"
printf "%-12s %-10s %s\n" "-----------" "------" "-------"
printf "%-12s %-10s %s\n" "docker" "$docker_status" "$docker_detail"
printf "%-12s %-10s %s\n" "wsl" "$wsl_status" "$wsl_detail"
printf "%-12s %-10s %s\n" "watcher" "$watcher_status" "$watcher_detail"
printf "%-12s %-10s %s\n" "shell" "$shell_status" "$shell_detail"

log_ok "Install complete"
