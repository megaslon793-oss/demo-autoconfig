#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="demo-autoconfig"
TMP_ROOT="/tmp/demo-autoconfig"
LOG_FILE="/var/log/demo-autoconfig.log"

DEFAULT_ARCHIVE_URL="https://codeload.github.com/megaslon793-oss/demo-autoconfig/tar.gz/refs/heads/main"
ARCHIVE_URL="${DEMO_REPO_ARCHIVE_URL:-$DEFAULT_ARCHIVE_URL}"
FALLBACK_ARCHIVE_URL="https://github.com/megaslon793-oss/demo-autoconfig/archive/refs/heads/main.tar.gz"
DOWNLOAD_RETRIES="${DEMO_DOWNLOAD_RETRIES:-12}"
DOWNLOAD_WAIT="${DEMO_DOWNLOAD_WAIT:-3}"
DOWNLOAD_TIMEOUT="${DEMO_DOWNLOAD_TIMEOUT:-25}"

status() {
  local level="$1"; shift
  printf '[%s] %s\n' "$level" "$*" >&2
  if [ "$(id -u)" -eq 0 ]; then
    { printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*"; } >> "$LOG_FILE" || true
  fi
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    status ERROR "Run as root. For pipe install use: curl -fsSL URL | sudo bash"
    exit 1
  fi
}

download_project() {
  mkdir -p "$TMP_ROOT"
  local archive="$TMP_ROOT/project.tar.gz"
  local extract="$TMP_ROOT/extract"
  rm -rf "$extract"
  mkdir -p "$extract"

  status OK "Downloading project archive"
  local urls="$ARCHIVE_URL"
  [ "$ARCHIVE_URL" = "$FALLBACK_ARCHIVE_URL" ] || urls="$urls $FALLBACK_ARCHIVE_URL"
  local url downloaded="no"
  for url in $urls; do
    status OK "Trying: $url"
    if download_url "$url" "$archive"; then
      downloaded="yes"
      break
    fi
  done
  if [ "$downloaded" != "yes" ] || [ ! -s "$archive" ]; then
    status ERROR "Download failed. Check internet, DNS, TLS certificates, proxy, or use offline copy."
    exit 1
  fi
  tar -xzf "$archive" -C "$extract"

  local project_dir
  project_dir="$(find "$extract" -maxdepth 2 -type f -name menu.sh -printf '%h\n' | head -n 1)"
  if [ -z "$project_dir" ]; then
    status ERROR "menu.sh not found in archive."
    exit 1
  fi

  chmod +x "$project_dir/menu.sh" "$project_dir"/modules/*.sh 2>/dev/null || true
  echo "$project_dir"
}

download_url() {
  local url="$1"
  local output="$2"
  rm -f "$output"
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL \
      --connect-timeout "$DOWNLOAD_TIMEOUT" \
      --max-time 300 \
      --retry "$DOWNLOAD_RETRIES" \
      --retry-delay "$DOWNLOAD_WAIT" \
      --retry-connrefused \
      "$url" -o "$output" && return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -4 \
      --tries="$DOWNLOAD_RETRIES" \
      --waitretry="$DOWNLOAD_WAIT" \
      --timeout="$DOWNLOAD_TIMEOUT" \
      --dns-timeout="$DOWNLOAD_TIMEOUT" \
      --connect-timeout="$DOWNLOAD_TIMEOUT" \
      --read-timeout=120 \
      -O "$output" "$url" && return 0
  else
    status ERROR "Neither curl nor wget is installed."
    exit 1
  fi
  rm -f "$output"
  return 1
}

main() {
  need_root "$@"
  mkdir -p "$(dirname "$LOG_FILE")" "$TMP_ROOT"
  touch "$LOG_FILE"

  local project_dir="${DEMO_PROJECT_DIR:-}"
  if [ -n "$project_dir" ] && [ -f "$project_dir/menu.sh" ]; then
    status OK "Using local project directory: $project_dir"
  else
    project_dir="$(download_project)"
  fi

  status OK "Starting menu"
  DEMO_BOOTSTRAP_TMP="$TMP_ROOT" bash "$project_dir/menu.sh"
}

main "$@"
