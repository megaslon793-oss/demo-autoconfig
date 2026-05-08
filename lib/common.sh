#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="/etc/demo-autoconfig"
CONFIG_FILE="$CONFIG_DIR/config.env"
TMP_DIR="/tmp/demo-autoconfig"
LOG_FILE="/var/log/demo-autoconfig.log"

# shellcheck source=lib/logging.sh
. "$PROJECT_DIR/lib/logging.sh"
# shellcheck source=lib/prompts.sh
. "$PROJECT_DIR/lib/prompts.sh"
# shellcheck source=lib/backup.sh
. "$PROJECT_DIR/lib/backup.sh"
# shellcheck source=lib/validators.sh
. "$PROJECT_DIR/lib/validators.sh"
# shellcheck source=lib/packages.sh
. "$PROJECT_DIR/lib/packages.sh"
# shellcheck source=lib/network.sh
. "$PROJECT_DIR/lib/network.sh"
# shellcheck source=lib/scenarios.sh
. "$PROJECT_DIR/lib/scenarios.sh"
# shellcheck source=lib/cleanup.sh
. "$PROJECT_DIR/lib/cleanup.sh"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_error "This project must be run as root."
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$TMP_DIR"
  init_log
}

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config not found: $CONFIG_FILE. Run Initial setup first."
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

is_role() {
  local role="$1"
  [ "${ROLE:-}" = "$role" ]
}

role_in() {
  local item
  for item in "$@"; do
    [ "${ROLE:-}" = "$item" ] && return 0
  done
  return 1
}

run_cmd() {
  local description="$1"; shift
  log_ok "$description"
  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [yes]: " answer
  answer="${answer:-yes}"
  case "$answer" in
    yes|y|Y|YES|Yes|da|DA|Da) return 0 ;;
    *) return 1 ;;
  esac
}

write_kv_config() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  : > "$file"
  chmod 600 "$file"
  while [ "$#" -gt 0 ]; do
    local key="$1"
    local value="$2"
    shift 2
    printf '%s=%q\n' "$key" "$value" >> "$file"
  done
}
