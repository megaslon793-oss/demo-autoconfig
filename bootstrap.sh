#!/bin/bash
set -u

DEFAULT_REPO_ARCHIVE_URL="https://github.com/megaslon793-oss/demo-autoconfig/archive/refs/heads/main.tar.gz"
REPO_ARCHIVE_URL="${DEMO_REPO_ARCHIVE_URL:-$DEFAULT_REPO_ARCHIVE_URL}"

TMP_DIR="/tmp/demo-autoconfig"
ARCHIVE_PATH="$TMP_DIR/project.tar.gz"
OPT_DIR="/opt/demo-autoconfig"

ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "Run as root: sudo bash bootstrap.sh"
  exit 1
fi

mkdir -p "$TMP_DIR"

download_archive() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fL --connect-timeout 10 --max-time 90 --retry 5 --retry-delay 3 -o "$ARCHIVE_PATH" "$REPO_ARCHIVE_URL"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -4 --timeout=20 --tries=5 -O "$ARCHIVE_PATH" "$REPO_ARCHIVE_URL"
    return $?
  fi
  return 1
}

extract_to_opt() {
  rm -rf "$TMP_DIR/extract"
  mkdir -p "$TMP_DIR/extract"
  tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR/extract" || return 1
  src_dir="$(find "$TMP_DIR/extract" -maxdepth 1 -type d -name 'demo-autoconfig-*' | head -n 1)"
  [ -n "$src_dir" ] || src_dir="$(find "$TMP_DIR/extract" -maxdepth 1 -type d | tail -n 1)"
  if [ ! -f "$src_dir/menu.sh" ]; then
    err "menu.sh not found in archive"
    return 1
  fi
  mkdir -p "$OPT_DIR"
  cp -a "$src_dir"/. "$OPT_DIR"/
  chmod +x "$OPT_DIR"/bootstrap.sh "$OPT_DIR"/menu.sh "$OPT_DIR"/modules/*.sh 2>/dev/null || true
  ok "Project saved to $OPT_DIR"
}

offline_fallback() {
  if [ -f "$OPT_DIR/menu.sh" ]; then
    warn "Using local copy: $OPT_DIR"
    return 0
  fi
  for local_archive in /mnt/additional/demo-autoconfig.tar.gz /mnt/additional/demo-autoconfig-module3.tar.gz /tmp/demo-autoconfig.tar.gz; do
    if [ -f "$local_archive" ]; then
      warn "Using local archive: $local_archive"
      cp "$local_archive" "$ARCHIVE_PATH"
      extract_to_opt && return 0
    fi
  done
  return 1
}

if download_archive; then
  ok "Downloaded project archive from $REPO_ARCHIVE_URL"
  extract_to_opt || { warn "Archive extract failed"; offline_fallback || exit 1; }
else
  warn "Could not download project archive"
  offline_fallback || { err "No internet archive and no local copy found"; exit 1; }
fi

if [ -f "$OPT_DIR/menu.sh" ]; then
  bash "$OPT_DIR/menu.sh"
else
  err "menu.sh not found in $OPT_DIR"
  exit 1
fi
