#!/usr/bin/env bash

LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

init_log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
}

log_line() {
  local level="$1"; shift
  local msg="$*"
  printf '[%s] %s\n' "$level" "$msg"
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_ok() { log_line OK "$@"; }
log_warn() { log_line WARN "$@"; }
log_error() { log_line ERROR "$@"; }
log_skip() { log_line SKIP "$@"; }
