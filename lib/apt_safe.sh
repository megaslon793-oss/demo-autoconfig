#!/bin/bash
# lib/apt_safe.sh
# Version: 0.6.19-apt-dns-rescue
#
# Fixes apt/DNS instability:
# - before apt writes sane resolv.conf
# - checks DNS resolution explicitly
# - does not treat apt_update_safe with "Temporary failure resolving" as OK
# - retries apt with packagekit stopped

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

DOMAIN="${DOMAIN:-au-team.irpo}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"

APT_DNS_SERVERS="${APT_DNS_SERVERS:-8.8.8.8 1.1.1.1 77.88.8.8 77.88.8.1}"
APT_UPDATE_MAX_ATTEMPTS="${APT_UPDATE_MAX_ATTEMPTS:-4}"

safe_log() {
  local level="$1"
  shift
  echo "$(date '+%F %T') [$level] $*" | tee -a "$LOG_FILE"
}

backup_resolv_conf_once() {
  mkdir -p /etc/demo-autoconfig/backups 2>/dev/null || true
  if [ -f /etc/resolv.conf ] && [ ! -f /etc/demo-autoconfig/backups/resolv.conf.before-apt-dns-rescue ]; then
    cp -a /etc/resolv.conf /etc/demo-autoconfig/backups/resolv.conf.before-apt-dns-rescue
  fi
}

write_apt_resolv_conf() {
  backup_resolv_conf_once

  # Do not put 127.0.0.1 here. Before package installation local DNS may not be ready.
  {
    echo "search ${DOMAIN}"
    echo "options timeout:2 attempts:2 rotate"
    for dns in $APT_DNS_SERVERS; do
      echo "nameserver $dns"
    done
    # Internal DNS goes after public DNS only as fallback.
    [ -n "$HQ_SRV_IP" ] && echo "nameserver $HQ_SRV_IP"
  } > /etc/resolv.conf

  safe_log OK "apt DNS resolv.conf written: $APT_DNS_SERVERS"
}

dns_resolves() {
  local name="$1"

  if command -v getent >/dev/null 2>&1; then
    getent hosts "$name" >/dev/null 2>&1 && return 0
  fi

  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$name" >/dev/null 2>&1 && return 0
  fi

  return 1
}

wait_for_dns_before_apt() {
  local name="${1:-deb.debian.org}"
  local i

  write_apt_resolv_conf

  for i in 1 2 3 4 5; do
    if dns_resolves "$name"; then
      safe_log OK "DNS resolves $name"
      return 0
    fi

    safe_log WARN "DNS still cannot resolve $name, attempt $i/5"
    sleep 2
    write_apt_resolv_conf
  done

  safe_log FAIL "DNS cannot resolve $name after retries"
  return 1
}

stop_apt_lockers() {
  systemctl stop packagekit.service >/dev/null 2>&1 || true
  systemctl stop apt-daily.service >/dev/null 2>&1 || true
  systemctl stop apt-daily-upgrade.service >/dev/null 2>&1 || true

  # Wait shortly for dpkg lock.
  local i
  for i in 1 2 3 4 5; do
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      safe_log WARN "apt/dpkg lock is busy, wait $i/5"
      sleep 2
    else
      return 0
    fi
  done

  return 0
}

apt_update_safe() {
  local attempt
  local out="/tmp/demo-autoconfig-apt-update.log"

  stop_apt_lockers

  for attempt in $(seq 1 "$APT_UPDATE_MAX_ATTEMPTS"); do
    wait_for_dns_before_apt "deb.debian.org"

    safe_log OK "apt_update_safe (attempt $attempt/$APT_UPDATE_MAX_ATTEMPTS)"
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::Retries=3 \
      -o Acquire::ForceIPv4=true \
      update 2>&1 | tee "$out"

    rc=${PIPESTATUS[0]}

    if grep -Eqi 'Temporary failure resolving|Could not resolve|Failed to fetch|Some index files failed|Не удалось получить|Временная ошибка при разрешении|Некоторые индексные файлы скачать не удалось' "$out"; then
      safe_log WARN "apt_update_safe had DNS/fetch warnings, retrying"
      sleep 3
      write_apt_resolv_conf
      continue
    fi

    if [ "$rc" -eq 0 ]; then
      safe_log OK "apt_update_safe completed cleanly"
      return 0
    fi

    safe_log WARN "apt_update_safe failed with code $rc"
    sleep 3
  done

  safe_log FAIL "apt_update_safe failed after $APT_UPDATE_MAX_ATTEMPTS attempts"
  return 1
}

apt_install_safe() {
  stop_apt_lockers
  apt_update_safe || safe_log WARN "apt update not clean, trying install with existing cache anyway"

  safe_log OK "apt_install_safe $*"
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::ForceIPv4=true \
    install -y "$@"
}

# Optional wrapper aliases for modules that source this file.
safe_apt_update() {
  apt_update_safe "$@"
}

safe_apt_install() {
  apt_install_safe "$@"
}
