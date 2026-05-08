#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

join_dns_servers_for_dhcp() {
  local raw="${DHCP_OPTION_DNS:-${DNS_SERVERS:-}}"
  local result="" item
  for item in $(printf '%s\n' "$raw" | tr ',' ' '); do
    [ -z "$item" ] && continue
    [ -n "$result" ] && result="$result, "
    result="$result$item"
  done
  printf '%s' "$result"
}

require_dhcp_value() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    log_error "DHCP variable is required: $name"
    return 1
  fi
}

dhcpd_cmd() {
  command -v dhcpd 2>/dev/null && return 0
  [ -x /usr/sbin/dhcpd ] && { printf '/usr/sbin/dhcpd'; return 0; }
  [ -x /sbin/dhcpd ] && { printf '/sbin/dhcpd'; return 0; }
  return 1
}

ensure_dhcp_interface_ready() {
  local iface="$1"
  local parent="${iface%.*}"
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
    return 0
  fi
  if command_exists ifup; then
    if [ "$parent" != "$iface" ]; then
      ifup "$parent" 2>/dev/null || true
    fi
    ifup "$iface" 2>/dev/null || true
  fi
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
    return 0
  fi
  log_error "DHCP interface has no IPv4 address: $iface. Apply /etc/network/interfaces before starting isc-dhcp-server."
  return 1
}

configure_dhcp() {
  [ "${DHCP_ENABLE:-no}" = "yes" ] || { log_skip "DHCP disabled by config"; return 0; }
  install_packages_no_autostart isc-dhcp-server
  backup_file /etc/default/isc-dhcp-server

  require_dhcp_value DHCP_IFACE
  require_dhcp_value DHCP_SUBNET
  require_dhcp_value DHCP_RANGE_START
  require_dhcp_value DHCP_RANGE_END
  require_dhcp_value DHCP_OPTION_ROUTERS
  require_dhcp_value DHCP_BROADCAST_ADDRESS

  local dhcp_dns
  dhcp_dns="$(join_dns_servers_for_dhcp)"
  if [ -z "$dhcp_dns" ]; then
    log_error "DHCP DNS is required: set DHCP_OPTION_DNS or DNS_SERVERS"
    return 1
  fi

  printf 'INTERFACESv4="%s"\nINTERFACESv6=""\n' "$DHCP_IFACE" > /etc/default/isc-dhcp-server

  backup_file /etc/dhcp/dhcpd.conf
  {
    printf 'authoritative;\n'
    printf 'ddns-update-style none;\n'
    printf 'default-lease-time 600;\n'
    printf 'max-lease-time 7200;\n'
    printf 'option domain-name "%s";\n\n' "${DHCP_DOMAIN:-$DOMAIN}"
    printf 'subnet %s {\n' "$DHCP_SUBNET"
    printf '  range %s %s;\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END"
    printf '  option routers %s;\n' "$DHCP_OPTION_ROUTERS"
    printf '  option domain-name-servers %s;\n' "$dhcp_dns"
    printf '  option broadcast-address %s;\n' "$DHCP_BROADCAST_ADDRESS"
    printf '}\n'
  } > /etc/dhcp/dhcpd.conf

  local dhcpd_bin
  if dhcpd_bin="$(dhcpd_cmd)"; then
    if ! "$dhcpd_bin" -t -cf /etc/dhcp/dhcpd.conf; then
      log_error "dhcpd config validation failed: /etc/dhcp/dhcpd.conf"
      return 1
    fi
  else
    log_warn "dhcpd binary not found; DHCP config syntax check skipped"
  fi

  ensure_dhcp_interface_ready "$DHCP_IFACE"
  enable_service isc-dhcp-server
  restart_service isc-dhcp-server
}

bind_first_zone() {
  local zone="${BIND_PRIMARY_ZONE:-}"
  if [ -z "$zone" ]; then
    zone="${BIND_ZONES:-}"
    zone="${zone%% *}"
  fi
  if [ -z "$zone" ]; then
    zone="${DOMAIN:-}"
  fi
  printf '%s' "$zone"
}

bind_abs_name() {
  local name="$1"
  local zone="$2"
  case "$name" in
    @) printf '%s.' "$zone" ;;
    *.) printf '%s' "$name" ;;
    *.*) printf '%s.' "$name" ;;
    *) printf '%s.%s.' "$name" "$zone" ;;
  esac
}

bind_zone_file_path() {
  local file="$1"
  case "$file" in
    /*) printf '%s' "$file" ;;
    *) printf '/etc/bind/zones/%s' "$file" ;;
  esac
}

render_bind_acl_block() {
  local item
  for item in $1; do
    printf '    %s;\n' "$item"
  done
}

render_bind_inline_acl() {
  local result="" item
  for item in $1; do
    [ -n "$result" ] && result="$result "
    result="$result$item;"
  done
  printf '%s' "$result"
}

render_bind_forward_zone() {
  local zone="$1"
  local zone_file="$2"
  local serial="${BIND_ZONE_SERIAL:-2025101302}"
  local ns_name="${BIND_NS_NAME:-ns1}"
  local ns_ip="${BIND_NS_IP:-192.168.100.2}"
  local record name ip

  {
    printf '$TTL 3600\n'
    printf '@ IN SOA %s %s (\n' "$(bind_abs_name "$ns_name" "$zone")" "$(bind_abs_name "${BIND_ADMIN_NAME:-admin}" "$zone")"
    printf '  %s ; Serial\n' "$serial"
    printf '  3600\n'
    printf '  1800\n'
    printf '  1209600\n'
    printf '  300 )\n\n'
    printf '@ IN NS %s\n' "$(bind_abs_name "$ns_name" "$zone")"
    printf '%s IN A %s\n\n' "$ns_name" "$ns_ip"
    for record in ${BIND_FORWARD_RECORDS:-}; do
      name="${record%%:*}"
      ip="${record#*:}"
      [ -z "$name" ] || [ -z "$ip" ] || [ "$name" = "$ip" ] && continue
      [ "$name" = "$ns_name" ] && continue
      printf '%s IN A %s\n' "$name" "$ip"
    done
  } > "$zone_file"
}

render_bind_reverse_zone() {
  local zone="$1"
  local reverse_zone="$2"
  local zone_file="$3"
  local serial="${BIND_ZONE_SERIAL:-2025101302}"
  local record record_zone rest ptr target

  {
    printf '$TTL 3600\n'
    printf '@ IN SOA %s %s (\n' "$(bind_abs_name "${BIND_NS_NAME:-ns1}" "$zone")" "$(bind_abs_name "${BIND_ADMIN_NAME:-admin}" "$zone")"
    printf '  %s 3600 1800 1209600 300 )\n' "$serial"
    printf '@ IN NS %s\n\n' "$(bind_abs_name "${BIND_NS_NAME:-ns1}" "$zone")"
    for record in ${BIND_REVERSE_RECORDS:-}; do
      record_zone="${record%%:*}"
      rest="${record#*:}"
      ptr="${rest%%:*}"
      target="${rest#*:}"
      [ "$record_zone" = "$reverse_zone" ] || continue
      [ -z "$ptr" ] || [ -z "$target" ] || [ "$ptr" = "$target" ] && continue
      printf '%s IN PTR %s\n' "$ptr" "$(bind_abs_name "$target" "$zone")"
    done
  } > "$zone_file"
}

configure_bind_base() {
  [ "${BIND_ENABLE:-no}" = "yes" ] || { log_skip "bind9 disabled by config"; return 0; }
  if ! install_packages bind9 bind9utils bind9-dnsutils; then
    install_packages bind9 bind9utils dnsutils
  fi

  local zone
  zone="$(bind_first_zone)"
  if [ -z "$zone" ]; then
    log_error "BIND zone is required: set BIND_ZONES or DOMAIN"
    return 1
  fi
  BIND_FORWARD_RECORDS="${BIND_FORWARD_RECORDS:-hq-rtr:192.168.100.1 br-rtr:192.168.255.1 hq-srv:192.168.100.2 hq-cli:192.168.200.2 br-srv:192.168.255.2 docker:172.16.1.1 web:172.16.2.1}"
  BIND_REVERSE_ZONES="${BIND_REVERSE_ZONES:-100.168.192.in-addr.arpa:db.192.168.100 200.168.192.in-addr.arpa:db.192.168.200 255.168.192.in-addr.arpa:db.192.168.255}"
  BIND_REVERSE_RECORDS="${BIND_REVERSE_RECORDS:-100.168.192.in-addr.arpa:1:hq-rtr 100.168.192.in-addr.arpa:2:hq-srv 200.168.192.in-addr.arpa:2:hq-cli 255.168.192.in-addr.arpa:1:br-rtr 255.168.192.in-addr.arpa:2:br-srv}"

  local bind_clients="${BIND_ALLOW_QUERY:-127.0.0.1 192.168.100.0/28 192.168.200.0/27 192.168.250.0/29 192.168.255.0/28 172.16.0.0/16 10.0.0.0/30}"
  local zones_dir="/etc/bind/zones"
  local forward_file="$zones_dir/db.$zone"
  mkdir -p "$zones_dir"

  backup_file /etc/bind/named.conf.options
  {
    printf 'options {\n'
    printf '    directory "/var/cache/bind";\n'
    printf '    listen-on { %s };\n' "$(render_bind_inline_acl "${BIND_LISTEN_ON:-any}")"
    printf '    listen-on-v6 { none; };\n'
    printf '    recursion yes;\n\n'
    printf '    allow-query {\n'
    render_bind_acl_block "$bind_clients"
    printf '    };\n\n'
    printf '    allow-recursion {\n'
    render_bind_acl_block "$bind_clients"
    printf '    };\n\n'
    printf '    allow-query-cache {\n'
    render_bind_acl_block "$bind_clients"
    printf '    };\n\n'
    printf '    forwarders {\n'
    render_bind_acl_block "${BIND_FORWARDERS:-77.88.8.7 77.88.8.3}"
    printf '    };\n'
    printf '    forward only;\n\n'
    printf '    dnssec-validation auto;\n'
    printf '};\n'
  } > /etc/bind/named.conf.options

  backup_file /etc/bind/named.conf.local
  {
    printf 'zone "%s" {\n' "$zone"
    printf '    type master;\n'
    printf '    file "%s";\n' "$forward_file"
    printf '};\n\n'
    local reverse_item reverse_zone reverse_file
    for reverse_item in ${BIND_REVERSE_ZONES:-}; do
      reverse_zone="${reverse_item%%:*}"
      reverse_file="${reverse_item#*:}"
      [ -z "$reverse_zone" ] || [ -z "$reverse_file" ] || [ "$reverse_zone" = "$reverse_file" ] && continue
      printf 'zone "%s" {\n' "$reverse_zone"
      printf '    type master;\n'
      printf '    file "%s";\n' "$(bind_zone_file_path "$reverse_file")"
      printf '};\n\n'
    done
  } > /etc/bind/named.conf.local

  backup_file "$forward_file"
  render_bind_forward_zone "$zone" "$forward_file"

  local reverse_item reverse_zone reverse_file reverse_path
  for reverse_item in ${BIND_REVERSE_ZONES:-}; do
    reverse_zone="${reverse_item%%:*}"
    reverse_file="${reverse_item#*:}"
    [ -z "$reverse_zone" ] || [ -z "$reverse_file" ] || [ "$reverse_zone" = "$reverse_file" ] && continue
    reverse_path="$(bind_zone_file_path "$reverse_file")"
    backup_file "$reverse_path"
    render_bind_reverse_zone "$zone" "$reverse_zone" "$reverse_path"
  done

  if command_exists named-checkconf; then
    if ! named-checkconf /etc/bind/named.conf; then
      log_error "named-checkconf failed: /etc/bind/named.conf"
      return 1
    fi
  fi
  if command_exists named-checkzone; then
    if ! named-checkzone "$zone" "$forward_file"; then
      log_error "named-checkzone failed: $forward_file"
      return 1
    fi
    for reverse_item in ${BIND_REVERSE_ZONES:-}; do
      reverse_zone="${reverse_item%%:*}"
      reverse_file="${reverse_item#*:}"
      [ -z "$reverse_zone" ] || [ -z "$reverse_file" ] || [ "$reverse_zone" = "$reverse_file" ] && continue
      if ! named-checkzone "$reverse_zone" "$(bind_zone_file_path "$reverse_file")"; then
        log_error "named-checkzone failed: $(bind_zone_file_path "$reverse_file")"
        return 1
      fi
    done
  fi

  enable_service_any bind9 named
  restart_service_any bind9 named
}

remove_old_ssh_dropin() {
  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin="$dropin_dir/99-demo-autoconfig.conf"
  if [ -f "$dropin" ]; then
    backup_file "$dropin"
    rm -f "$dropin"
    log_ok "Old managed SSH drop-in removed: $dropin"
  fi
}

set_sshd_directive() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[#[:space:]]*" key "([[:space:]]+|$)" {
      if (!done) {
        print key " " value
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) {
        print key " " value
      }
    }
  ' "$file" > "$tmp"
  cp "$tmp" "$file"
  rm -f "$tmp"
}

sshd_binary() {
  if command_exists sshd; then
    command -v sshd
  elif [ -x /usr/sbin/sshd ]; then
    printf '/usr/sbin/sshd'
  else
    return 1
  fi
}

ensure_local_user() {
  local user="$1"
  local password="${2:-}"
  local uid="${3:-}"
  local sudo_access="${4:-no}"
  [ -n "$user" ] || return 0

  if id "$user" >/dev/null 2>&1; then
    log_skip "User already exists: $user"
  else
    local args=(-m -s /bin/bash)
    if [ -n "$uid" ] && ! getent passwd "$uid" >/dev/null 2>&1; then
      args+=(-u "$uid")
    fi
    useradd "${args[@]}" "$user"
    log_ok "User created: $user"
  fi

  usermod -s /bin/bash "$user" 2>/dev/null || true
  if [ -n "$password" ]; then
    printf '%s:%s\n' "$user" "$password" | chpasswd
    log_ok "Password configured for user: $user"
  fi

  if [ "$sudo_access" = "yes" ]; then
    install_packages sudo
    usermod -aG sudo "$user" 2>/dev/null || true
    mkdir -p /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "/etc/sudoers.d/$user"
    chmod 440 "/etc/sudoers.d/$user"
    log_ok "Passwordless sudo configured for user: $user"
  fi
}

configure_role_users() {
  case "${ROLE:-}" in
    HQ-SRV|BR-SRV)
      ensure_local_user "${SSH_REMOTE_USER:-remote_user}" "" "" "no"
      ensure_local_user "${SSH_USER:-sshuser}" "${SSH_PASSWORD:-P@ssw0rd}" "${SSH_USER_UID:-2026}" "yes"
      ;;
    HQ-RTR|BR-RTR)
      ensure_local_user "${SSH_ROUTER_USER:-net_admin}" "${SSH_ROUTER_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}" "" "yes"
      ensure_local_user "${SSH_USER:-sshuser}" "${SSH_PASSWORD:-P@ssw0rd}" "${SSH_USER_UID:-2026}" "yes"
      ;;
    *)
      log_skip "No managed local users required for role: ${ROLE:-unknown}"
      ;;
  esac
}

ensure_ssh_client_include() {
  local conf="/etc/ssh/ssh_config"
  [ -f "$conf" ] || touch "$conf"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf' "$conf"; then
    return 0
  fi
  backup_file "$conf"
  local tmp
  tmp="$(mktemp)"
  {
    printf 'Include /etc/ssh/ssh_config.d/*.conf\n'
    cat "$conf"
  } > "$tmp"
  cp "$tmp" "$conf"
  rm -f "$tmp"
}

configure_ssh_client_aliases() {
  [ "${SSH_CLIENT_CONFIG:-no}" = "yes" ] || [ "${ROLE:-}" = "HQ-CLI" ] || return 0
  install_packages openssh-client
  mkdir -p /etc/ssh/ssh_config.d
  ensure_ssh_client_include

  local conf="/etc/ssh/ssh_config.d/99-demo-autoconfig.conf"
  local domain="${DOMAIN:-au-team.irpo}"
  local server_user="${SSH_USER:-sshuser}"
  local server_port="${SSH_SERVER_PORT:-${SSH_PORT:-2026}}"
  local router_user="${SSH_ROUTER_USER:-net_admin}"
  local router_port="${SSH_ROUTER_PORT:-2026}"
  backup_file "$conf"
  cat > "$conf" <<EOF
Host hq-srv hq-srv.$domain
    HostName hq-srv.$domain
    User $server_user
    Port $server_port
    StrictHostKeyChecking accept-new

Host br-srv br-srv.$domain
    HostName br-srv.$domain
    User $server_user
    Port $server_port
    StrictHostKeyChecking accept-new

Host hq-rtr hq-rtr.$domain
    HostName hq-rtr.$domain
    User $router_user
    Port $router_port
    StrictHostKeyChecking accept-new

Host br-rtr br-rtr.$domain
    HostName br-rtr.$domain
    User $router_user
    Port $router_port
    StrictHostKeyChecking accept-new
EOF
  chmod 644 "$conf"
  log_ok "SSH client aliases configured: hq-srv, br-srv, hq-rtr, br-rtr"
}

configure_ssh_service() {
  install_packages openssh-client
  install_packages openssh-server
  remove_old_ssh_dropin
  configure_role_users
  configure_ssh_client_aliases

  if [ "${SSH_HARDENING:-no}" = "yes" ]; then
    local conf="/etc/ssh/sshd_config"
    local allow_users="${SSH_ALLOW_USERS:-}"
    case "${ROLE:-}" in
      HQ-SRV|BR-SRV) [ -n "$allow_users" ] || allow_users="${SSH_USER:-sshuser}" ;;
      HQ-RTR|BR-RTR) [ -n "$allow_users" ] || allow_users="${SSH_ROUTER_USER:-net_admin} ${SSH_USER:-sshuser}" ;;
    esac
    [ -f "$conf" ] || touch "$conf"
    backup_file "$conf"
    set_sshd_directive "$conf" Port "${SSH_PORT:-2026}"
    set_sshd_directive "$conf" PermitRootLogin "${SSH_PERMIT_ROOT_LOGIN:-no}"
    set_sshd_directive "$conf" PasswordAuthentication "${SSH_PASSWORD_AUTHENTICATION:-yes}"
    set_sshd_directive "$conf" KbdInteractiveAuthentication yes
    set_sshd_directive "$conf" UsePAM yes
    set_sshd_directive "$conf" MaxAuthTries "${SSH_MAX_AUTH_TRIES:-2}"
    [ -n "$allow_users" ] && set_sshd_directive "$conf" AllowUsers "$allow_users"
    if [ -n "${SSH_BANNER_TEXT:-}" ]; then
      printf '%s\n' "$SSH_BANNER_TEXT" > /etc/issue.net
      set_sshd_directive "$conf" Banner /etc/issue.net
    fi
  else
    log_skip "SSH hardening disabled by config; installing and starting ssh only"
  fi

  local sshd_cmd
  mkdir -p /run/sshd
  if sshd_cmd="$(sshd_binary)" && "$sshd_cmd" -t; then
    enable_service_any ssh sshd
    restart_service_any ssh sshd
  else
    log_error "sshd config validation failed. See /etc/ssh/sshd_config"
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
  [ -n "${INTERNET_TEST_IP:-}" ] && ping -c 1 -W 3 "$INTERNET_TEST_IP" >/dev/null 2>&1 && log_ok "Internet test ping OK: $INTERNET_TEST_IP" || log_warn "Internet test ping skipped or failed"
  if [ "${ROLE:-}" != "ISP" ] && [ -n "${DOMAIN:-}" ] && command_exists nslookup; then
    local dns_check_server="${DNS_CHECK_SERVER:-192.168.100.2}"
    [ "${ROLE:-}" = "HQ-SRV" ] && dns_check_server="${DNS_CHECK_SERVER:-127.0.0.1}"
    nslookup "hq-srv.$DOMAIN" "$dns_check_server" >/dev/null 2>&1 && log_ok "DNS lookup OK via $dns_check_server" || log_warn "DNS lookup failed via $dns_check_server"
  fi
  case "${ROLE:-}" in
    HQ-SRV|BR-SRV)
      id "${SSH_USER:-sshuser}" >/dev/null 2>&1 && log_ok "SSH server user exists: ${SSH_USER:-sshuser}" || log_warn "SSH server user missing: ${SSH_USER:-sshuser}"
      id "${SSH_REMOTE_USER:-remote_user}" >/dev/null 2>&1 && log_ok "Additional server user exists: ${SSH_REMOTE_USER:-remote_user}" || log_warn "Additional server user missing: ${SSH_REMOTE_USER:-remote_user}"
      ;;
    HQ-RTR|BR-RTR)
      id "${SSH_ROUTER_USER:-net_admin}" >/dev/null 2>&1 && log_ok "Router SSH user exists: ${SSH_ROUTER_USER:-net_admin}" || log_warn "Router SSH user missing: ${SSH_ROUTER_USER:-net_admin}"
      id "${SSH_USER:-sshuser}" >/dev/null 2>&1 && log_ok "Router additional SSH user exists: ${SSH_USER:-sshuser}" || log_warn "Router additional SSH user missing: ${SSH_USER:-sshuser}"
      ;;
  esac
  if [ "${SSH_HARDENING:-no}" = "yes" ] && command_exists ss; then
    ss -ltn | grep -q ":${SSH_PORT:-2026} " && log_ok "SSH listens on port ${SSH_PORT:-2026}" || log_warn "SSH is not listening on port ${SSH_PORT:-2026}"
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
  apply_networking_changes
  configure_resolv_conf
  ensure_default_route
  configure_static_routes
  configure_gre
  configure_frr_ospf
  configure_dhcp
  configure_bind_base
  configure_ssh_service
  reconcile_routing_after_network_restart
  ensure_default_route
  configure_resolv_conf
  post_checks
}

main "$@"
