#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

section() {
  printf '\n===== %s =====\n' "$1" | tee -a "$LOG_FILE"
}

run_diag() {
  local title="$1"; shift
  section "$title"
  "$@" 2>&1 | tee -a "$LOG_FILE" || log_warn "Diagnostic failed: $title"
}

run_diag "ip a" ip a
run_diag "ip route" ip route

[ -n "${DEFAULT_GW:-}" ] && run_diag "ping gateway $DEFAULT_GW" ping -c 3 -W 2 "$DEFAULT_GW" || log_skip "DEFAULT_GW is empty"
[ -n "${INTERNET_TEST_IP:-}" ] && run_diag "ping internet IP $INTERNET_TEST_IP" ping -c 3 -W 2 "$INTERNET_TEST_IP" || log_skip "INTERNET_TEST_IP is empty"

if command_exists dig; then
  first_dns_name="${DOMAIN:-example.com}"
  run_diag "DNS lookup $first_dns_name" dig "$first_dns_name"
elif command_exists getent; then
  run_diag "DNS lookup ${DOMAIN:-example.com}" getent hosts "${DOMAIN:-example.com}"
else
  log_skip "DNS lookup tools not found"
fi

if command_exists nslookup && [ -n "${DOMAIN:-}" ]; then
  dns_check_server="${DNS_CHECK_SERVER:-192.168.100.2}"
  [ "${ROLE:-}" = "HQ-SRV" ] && dns_check_server="${DNS_CHECK_SERVER:-127.0.0.1}"
  run_diag "nslookup ${DOMAIN} via ${dns_check_server}" nslookup "$DOMAIN" "$dns_check_server"
  run_diag "nslookup hq-srv.${DOMAIN} via ${dns_check_server}" nslookup "hq-srv.$DOMAIN" "$dns_check_server"
fi


section "DNS / resolv.conf role check"
run_diag "cat /etc/resolv.conf" cat /etc/resolv.conf
if grep -q '^nameserver 127\.0\.0\.1' /etc/resolv.conf; then
  if [ "${ROLE:-}" = "HQ-SRV" ] && { systemctl is-active --quiet bind9 2>/dev/null || systemctl is-active --quiet named 2>/dev/null; }; then
    log_ok "localhost DNS is valid on HQ-SRV because bind9/named is active"
  elif [ "${ROLE:-}" = "BR-SRV" ] && systemctl is-active --quiet samba-ad-dc 2>/dev/null; then
    log_ok "localhost DNS is valid on BR-SRV because samba-ad-dc is active"
  else
    log_error "localhost DNS configured but local DNS service is inactive for role ${ROLE:-unknown}"
  fi
else
  log_ok "localhost is not used as primary DNS on this role"
fi

if command_exists nslookup; then
  run_diag "external DNS google.com" nslookup google.com
  run_diag "internal DNS hq-srv.${DOMAIN:-au-team.irpo}" nslookup "hq-srv.${DOMAIN:-au-team.irpo}" "${HQ_SRV_IP:-192.168.100.2}"
  run_diag "internal DNS br-srv.${DOMAIN:-au-team.irpo}" nslookup "br-srv.${DOMAIN:-au-team.irpo}" "${HQ_SRV_IP:-192.168.100.2}"
else
  log_warn "nslookup not installed; install dnsutils/bind9-dnsutils"
fi

if [ "${GRE_ENABLE:-no}" = "yes" ]; then
  run_diag "GRE link ${GRE_NAME:-gre1}" ip -d link show "${GRE_NAME:-gre1}"
else
  log_skip "GRE disabled by config"
fi

if command_exists vtysh; then
  run_diag "show ip ospf neighbor" vtysh -c "show ip ospf neighbor"
else
  log_skip "vtysh not installed"
fi

for svc in ssh frr isc-dhcp-server bind9 samba-ad-dc smbd nmbd winbind chrony docker apache2 mariadb nginx cups rsyslog fail2ban; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    run_diag "systemctl status $svc" systemctl --no-pager --full status "$svc"
  else
    log_skip "Service not found: $svc"
  fi
done

command_exists docker && run_diag "docker ps" docker ps || log_skip "docker not installed"
command_exists docker && run_diag "docker images" docker images || true

command_exists samba-tool && run_diag "samba-tool domain info" samba-tool domain info 127.0.0.1 || log_skip "samba-tool not installed"
command_exists klist && run_diag "klist" klist || log_skip "klist not installed"
command_exists smbclient && run_diag "smbclient check" smbclient -L localhost -N || log_skip "smbclient not installed"
command_exists exportfs && run_diag "exportfs -v" exportfs -v || log_skip "exportfs not installed"
command_exists chronyc && run_diag "chronyc sources" chronyc sources || log_skip "chronyc not installed"
command_exists lpstat && run_diag "lpstat" lpstat -t || log_skip "lpstat not installed"

case "${ROLE:-}" in
  HQ-SRV|BR-SRV)
    run_diag "user ${SSH_USER:-sshuser}" id "${SSH_USER:-sshuser}"
    run_diag "user ${SSH_REMOTE_USER:-user}" id "${SSH_REMOTE_USER:-user}"
    ;;
  HQ-RTR|BR-RTR)
    run_diag "user ${SSH_ROUTER_EXTRA_USER:-user}" id "${SSH_ROUTER_EXTRA_USER:-user}"
    run_diag "user ${SSH_ROUTER_USER:-net_admin}" id "${SSH_ROUTER_USER:-net_admin}"
    ;;
esac

[ -n "${SSH_PORT:-}" ] && command_exists ss && run_diag "ssh listen port ${SSH_PORT:-}" sh -c "ss -ltn | grep ':${SSH_PORT:-} '" || true

log_ok "Diagnostics finished"
