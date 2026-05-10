if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/usr/bin/env bash

pkg_installed() {
  dpkg -s "$1" 2>/dev/null | grep -qx 'Status: install ok installed'
}

stop_packagekit_for_apt() {
  if command_exists systemctl && systemctl list-unit-files packagekit.service >/dev/null 2>&1; then
    if systemctl is-active --quiet packagekit 2>/dev/null; then
      log_warn "packagekit.service is active and can hold dpkg lock; stopping it before apt"
      systemctl stop packagekit 2>/dev/null || true
      sleep 2
    fi
  fi
}

apt_get_retry() {
  local attempt=1
  local max_attempts="${APT_RETRIES:-4}"
  local lock_timeout="${APT_LOCK_TIMEOUT:-180}"
  local rc=0
  local tmp
  tmp="$(mktemp)"

  while [ "$attempt" -le "$max_attempts" ]; do
    stop_packagekit_for_apt
    log_ok "apt-get $* (attempt $attempt/$max_attempts)"
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=$lock_timeout" "$@" >"$tmp" 2>&1
    rc=$?
    set -e
    cat "$tmp"
    if [ "$rc" -eq 0 ]; then
      rm -f "$tmp"
      return 0
    fi

    if grep -qiE 'lock-frontend|Could not get lock|Unable to acquire|dpkg frontend lock|packagekitd' "$tmp"; then
      log_warn "apt/dpkg lock is busy. Waiting before retry..."
      sleep 10
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "$tmp"
    return "$rc"
  done

  rm -f "$tmp"
  log_error "apt-get failed after waiting for dpkg lock"
  return "$rc"
}

install_packages() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if pkg_installed "$pkg"; then
      log_skip "Package already installed: $pkg"
    else
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if ! command_exists apt-get; then
    log_warn "apt-get not found. Install manually: ${missing[*]}"
    return 1
  fi

  log_ok "Installing packages: ${missing[*]}"
  apt_get_retry update
  apt_get_retry install -y "${missing[@]}"
}

install_packages_no_autostart() {
  local policy="/usr/sbin/policy-rc.d"
  local backup=""
  local existed="no"
  local rc

  mkdir -p "$TMP_DIR"
  if [ -e "$policy" ]; then
    existed="yes"
    backup="$TMP_DIR/policy-rc.d.$$.bak"
    cp -a "$policy" "$backup"
  fi

  {
    printf '#!/bin/sh\n'
    printf 'exit 101\n'
  } > "$policy"
  chmod 755 "$policy"

  set +e
  install_packages "$@"
  rc=$?
  set -e

  if [ "$existed" = "yes" ]; then
    cp -a "$backup" "$policy"
    rm -f "$backup"
  else
    rm -f "$policy"
  fi

  return "$rc"
}

enable_service() {
  local service="$1"
  if ! systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
    log_warn "Service unit not found: $service"
    return 0
  fi
  if systemctl is-enabled "$service" >/dev/null 2>&1; then
    log_skip "Service already enabled: $service"
  else
    systemctl enable "$service"
    log_ok "Service enabled: $service"
  fi
}

enable_service_any() {
  local service
  for service in "$@"; do
    if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
      enable_service "$service"
      return 0
    fi
  done
  log_warn "Service unit not found, enable skipped: $*"
}

restart_service() {
  local service="$1"
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
    systemctl restart "$service"
    log_ok "Service restarted: $service"
  else
    log_warn "Service unit not found, restart skipped: $service"
  fi
}

restart_service_any() {
  local service
  for service in "$@"; do
    if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
      restart_service "$service"
      return 0
    fi
  done
  log_warn "Service unit not found, restart skipped: $*"
}
