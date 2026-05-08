#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

configure_dhcp() {
  [ "${DHCP_ENABLE:-no}" = "yes" ] || { log_skip "DHCP disabled by config"; return 0; }
  install_packages isc-dhcp-server
  backup_file /etc/default/isc-dhcp-server
  printf 'INTERFACESv4="%s"\nINTERFACESv6=""\n' "${DHCP_IFACE:-}" > /etc/default/isc-dhcp-server

  if [ -z "${DHCP_SUBNET:-}" ] || [ -z "${DHCP_RANGE_START:-}" ] || [ -z "${DHCP_RANGE_END:-}" ]; then
    log_warn "DHCP variables are incomplete. Package installed, config not rewritten."
    return 0
  fi

  backup_file /etc/dhcp/dhcpd.conf
  cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
ddns-update-style none;
option domain-name "${DHCP_DOMAIN:-$DOMAIN}";
option domain-name-servers ${DHCP_OPTION_DNS:-$DNS_SERVERS};

# TODO: DHCP_SUBNET is intentionally editable. Use Debian dhcpd syntax below.
# Example: subnet 192.168.10.0 netmask 255.255.255.0 { ... }
subnet ${DHCP_SUBNET} {
  range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
  option routers ${DHCP_OPTION_ROUTERS};
$(if [ -n "${DHCP_BROADCAST_ADDRESS:-}" ]; then printf '  option broadcast-address %s;\n' "$DHCP_BROADCAST_ADDRESS"; fi)
}
EOF
  enable_service isc-dhcp-server
  restart_service isc-dhcp-server
}

configure_bind_base() {
  [ "${BIND_ENABLE:-no}" = "yes" ] || { log_skip "bind9 disabled by config"; return 0; }
  install_packages bind9 bind9utils dnsutils
  enable_service bind9
  restart_service bind9
  log_warn "Zone creation is intentionally not hard-coded. Edit /etc/bind or extend module1 with BIND_ZONES."
}

configure_ssh_hardening() {
  [ "${SSH_HARDENING:-yes}" = "yes" ] || { log_skip "SSH hardening disabled by config"; return 0; }
  install_packages openssh-server
  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin="$dropin_dir/99-demo-autoconfig.conf"
  mkdir -p "$dropin_dir"
  backup_file "$dropin"
  {
    printf 'Port %s\n' "${SSH_PORT:-22}"
    printf 'PermitRootLogin %s\n' "${SSH_PERMIT_ROOT_LOGIN:-prohibit-password}"
    printf 'PasswordAuthentication %s\n' "${SSH_PASSWORD_AUTHENTICATION:-yes}"
    [ -n "${SSH_MAX_AUTH_TRIES:-}" ] && printf 'MaxAuthTries %s\n' "$SSH_MAX_AUTH_TRIES"
    [ -n "${SSH_ALLOW_USERS:-}" ] && printf 'AllowUsers %s\n' "$SSH_ALLOW_USERS"
    if [ -n "${SSH_BANNER_TEXT:-}" ]; then
      printf '%s\n' "$SSH_BANNER_TEXT" > /etc/issue.net
      printf 'Banner /etc/issue.net\n'
    fi
    printf 'X11Forwarding no\n'
    printf 'ClientAliveInterval 300\n'
    printf 'ClientAliveCountMax 2\n'
  } > "$dropin"
  if sshd -t; then
    enable_service ssh
    restart_service ssh
  else
    log_error "sshd config validation failed. See $dropin"
    return 1
  fi
}

apply_networking_changes() {
  case "${NETWORK_APPLY_ACTION:-restart}" in
    restart|yes)
      if command_exists systemctl && systemctl list-unit-files networking.service >/dev/null 2>&1; then
        if systemctl restart networking; then
          log_ok "Networking restarted"
        else
          log_warn "systemctl restart networking failed"
        fi
      elif command_exists service; then
        if service networking restart; then
          log_ok "Networking restarted"
        else
          log_warn "service networking restart failed"
        fi
      else
        log_warn "Could not restart networking: systemctl/service not found"
      fi
      ;;
    reboot)
      log_warn "Reboot requested by NETWORK_APPLY_ACTION=reboot"
      if command_exists systemctl; then
        systemctl reboot
      else
        reboot
      fi
      ;;
    no|skip|none)
      log_skip "Networking restart disabled by config"
      ;;
    *)
      log_warn "Unknown NETWORK_APPLY_ACTION=${NETWORK_APPLY_ACTION}. Networking restart skipped."
      ;;
  esac
}

reconcile_routing_after_network_restart() {
  configure_static_routes || true
  configure_gre || true
  if [ "${OSPF_ENABLE:-no}" = "yes" ]; then
    if command_exists systemctl && systemctl list-unit-files frr.service >/dev/null 2>&1; then
      if systemctl restart frr; then
        log_ok "FRR restarted after networking"
      else
        log_warn "FRR restart after networking failed"
      fi
    fi
  fi
}

post_checks() {
  log_ok "Module 1 checks"
  ip -br addr || true
  ip route || true
  [ -n "${DEFAULT_GW:-}" ] && ping -c 1 -W 2 "$DEFAULT_GW" >/dev/null 2>&1 && log_ok "Gateway ping OK" || log_warn "Gateway ping skipped or failed"
  if [ "${GRE_ENABLE:-no}" = "yes" ]; then
    ip link show "${GRE_NAME:-gre1}" >/dev/null 2>&1 && log_ok "GRE exists: ${GRE_NAME:-gre1}" || log_warn "GRE missing: ${GRE_NAME:-gre1}"
  fi
  if [ "${OSPF_ENABLE:-no}" = "yes" ] && command_exists vtysh; then
    vtysh -c 'show ip ospf neighbor' || true
  fi
}

main() {
  set_hostname_idempotent "$HOSTNAME"
  configure_hosts
  configure_resolv_conf
  configure_network_interfaces

  local forward="$IP_FORWARD"
  if [ "$forward" = "auto" ]; then
    forward="no"
    role_in ISP HQ-RTR BR-RTR && forward="yes"
  fi
  set_ip_forward "$forward"

  configure_nat
  configure_static_routes
  configure_gre
  configure_frr_ospf
  configure_dhcp
  configure_bind_base
  configure_ssh_hardening
  apply_networking_changes
  reconcile_routing_after_network_restart
  post_checks
}

main "$@"
