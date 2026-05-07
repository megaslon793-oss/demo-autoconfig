#!/usr/bin/env bash

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
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
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
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

restart_service() {
  local service="$1"
  if systemctl list-unit-files "$service.service" >/dev/null 2>&1; then
    systemctl restart "$service"
    log_ok "Service restarted: $service"
  else
    log_warn "Service unit not found, restart skipped: $service"
  fi
}
