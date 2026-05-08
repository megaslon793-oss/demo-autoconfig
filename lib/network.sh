#!/usr/bin/env bash

short_hostname() {
  local value="${1:-}"
  printf '%s' "${value%%.*}"
}

fqdn_hostname() {
  local name="${1:-}"
  local domain="${2:-}"
  if [ -z "$name" ]; then
    return 0
  fi
  case "$name" in
    *.*) printf '%s' "$name" ;;
    *) [ -n "$domain" ] && printf '%s.%s' "$name" "$domain" || printf '%s' "$name" ;;
  esac
}

set_hostname_idempotent() {
  local new_hostname
  new_hostname="$(fqdn_hostname "${1:-}" "${DOMAIN:-}")"
  if [ -z "$new_hostname" ]; then
    log_skip "Hostname is empty"
    return 0
  fi
  if [ "$(hostname)" = "$new_hostname" ]; then
    log_skip "Hostname already set: $new_hostname"
    return 0
  fi
  hostnamectl set-hostname "$new_hostname"
  log_ok "Hostname set: $new_hostname"
}

configure_hosts() {
  backup_file /etc/hosts
  local fqdn short
  fqdn="$(fqdn_hostname "${HOSTNAME:-}" "${DOMAIN:-}")"
  short="$(short_hostname "${HOSTNAME:-}")"
  awk -v fqdn="$fqdn" -v short="$short" \
    '$1 == "127.0.1.1" && $2 == fqdn && $3 == short { found = 1 } END { exit found ? 0 : 1 }' \
    /etc/hosts 2>/dev/null || {
    sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
    printf '127.0.1.1 %s %s\n' "$fqdn" "$short" >> /etc/hosts
  }
  if [ -n "${HOSTS_ENTRIES:-}" ]; then
    local old_ifs="$IFS"
    local entry
    IFS=';'
    for entry in $HOSTS_ENTRIES; do
      IFS="$old_ifs"
      entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$entry" ] && continue
      if grep -qxF "$entry" /etc/hosts; then
        log_skip "/etc/hosts entry exists: $entry"
      else
        printf '%s\n' "$entry" >> /etc/hosts
        log_ok "/etc/hosts entry added: $entry"
      fi
      IFS=';'
    done
    IFS="$old_ifs"
  fi
  log_ok "/etc/hosts configured"
}

configure_resolv_conf() {
  if [ "${LOCK_RESOLV_CONF:-no}" = "yes" ] && command_exists chattr; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  backup_file /etc/resolv.conf
  {
    [ -n "${DOMAIN:-}" ] && printf 'search %s\n' "$DOMAIN"
    local dns
    for dns in ${DNS_SERVERS:-}; do
      printf 'nameserver %s\n' "$dns"
    done
  } > /etc/resolv.conf
  if [ "${LOCK_RESOLV_CONF:-no}" = "yes" ] && command_exists chattr; then
    chattr +i /etc/resolv.conf || log_warn "Could not lock /etc/resolv.conf with chattr +i"
  fi
  log_ok "/etc/resolv.conf configured"
}

render_interfaces_file() {
  local tmp="$1"
  {
    printf 'source /etc/network/interfaces.d/*\n\n'
    printf 'auto lo\niface lo inet loopback\n\n'
    local item iface cfg
    for item in ${IPV4_CONFIGS:-}; do
      iface="${item%%:*}"
      cfg="${item#*:}"
      [ -z "$iface" ] && continue
      printf 'auto %s\n' "$iface"
      if [ "$cfg" = "dhcp" ]; then
        printf 'iface %s inet dhcp\n' "$iface"
        render_interface_route_hooks "$iface"
        printf '\n'
      elif [ "$cfg" = "manual" ]; then
        printf 'iface %s inet manual\n' "$iface"
        render_interface_route_hooks "$iface"
        printf '\n'
      elif [ -n "$cfg" ]; then
        printf 'iface %s inet static\n' "$iface"
        printf '    address %s\n' "$cfg"
        if [ "$iface" = "${WAN_IFACE:-}" ] || [ "$iface" = "${LAN_IFACE:-}" ]; then
          [ -n "${DEFAULT_GW:-}" ] && [ "$iface" = "${WAN_IFACE:-}" ] && printf '    gateway %s\n' "$DEFAULT_GW"
        fi
        render_interface_route_hooks "$iface"
        printf '\n'
      fi
    done
    render_gre_interfaces_stanza
  } > "$tmp"
}

route_parts() {
  local route="$1"
  ROUTE_DEST="${route%%:*}"
  local rest="${route#*:}"
  ROUTE_VIA="${rest%%:*}"
  ROUTE_DEV=""
  if [ "$rest" != "$ROUTE_VIA" ]; then
    ROUTE_DEV="${rest#*:}"
  fi
}

render_interface_route_hooks() {
  local iface="$1"
  [ -n "${STATIC_ROUTES_IFACE:-}" ] || return 0
  [ "$iface" = "$STATIC_ROUTES_IFACE" ] || return 0
  local route
  for route in ${STATIC_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    printf '    up ip route add %s via %s' "$ROUTE_DEST" "$ROUTE_VIA"
    [ -n "$ROUTE_DEV" ] && printf ' dev %s' "$ROUTE_DEV"
    printf '\n'
  done
}

prefix_to_netmask() {
  case "$1" in
    0) printf '0.0.0.0' ;;
    1) printf '128.0.0.0' ;;
    2) printf '192.0.0.0' ;;
    3) printf '224.0.0.0' ;;
    4) printf '240.0.0.0' ;;
    5) printf '248.0.0.0' ;;
    6) printf '252.0.0.0' ;;
    7) printf '254.0.0.0' ;;
    8) printf '255.0.0.0' ;;
    9) printf '255.128.0.0' ;;
    10) printf '255.192.0.0' ;;
    11) printf '255.224.0.0' ;;
    12) printf '255.240.0.0' ;;
    13) printf '255.248.0.0' ;;
    14) printf '255.252.0.0' ;;
    15) printf '255.254.0.0' ;;
    16) printf '255.255.0.0' ;;
    17) printf '255.255.128.0' ;;
    18) printf '255.255.192.0' ;;
    19) printf '255.255.224.0' ;;
    20) printf '255.255.240.0' ;;
    21) printf '255.255.248.0' ;;
    22) printf '255.255.252.0' ;;
    23) printf '255.255.254.0' ;;
    24) printf '255.255.255.0' ;;
    25) printf '255.255.255.128' ;;
    26) printf '255.255.255.192' ;;
    27) printf '255.255.255.224' ;;
    28) printf '255.255.255.240' ;;
    29) printf '255.255.255.248' ;;
    30) printf '255.255.255.252' ;;
    31) printf '255.255.255.254' ;;
    32) printf '255.255.255.255' ;;
    *) printf '' ;;
  esac
}

render_gre_interfaces_stanza() {
  [ "${GRE_ENABLE:-no}" = "yes" ] || return 0
  [ -n "${GRE_LOCAL_IP:-}" ] && [ -n "${GRE_REMOTE_IP:-}" ] && [ -n "${GRE_TUNNEL_LOCAL_CIDR:-}" ] || return 0
  local tunnel_ip prefix netmask route
  tunnel_ip="${GRE_TUNNEL_LOCAL_CIDR%%/*}"
  prefix="${GRE_TUNNEL_LOCAL_CIDR#*/}"
  netmask="$(prefix_to_netmask "$prefix")"
  printf 'auto %s\n' "${GRE_NAME:-gre30}"
  printf 'iface %s inet tunnel\n' "${GRE_NAME:-gre30}"
  printf '    address %s\n' "$tunnel_ip"
  [ -n "$netmask" ] && printf '    netmask %s\n' "$netmask"
  printf '    mode gre\n'
  printf '    local %s\n' "$GRE_LOCAL_IP"
  printf '    endpoint %s\n' "$GRE_REMOTE_IP"
  printf '    ttl %s\n' "${GRE_TTL:-225}"
  for route in ${GRE_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    printf '    post-up ip route add %s via %s\n' "$ROUTE_DEST" "$ROUTE_VIA"
  done
  printf '\n'
}

configure_vlan_support() {
  case " ${IPV4_CONFIGS:-} " in
    *.*:*)
      install_packages vlan || true
      if command_exists modprobe; then
        modprobe 8021q || log_warn "Could not load 8021q module"
      fi
      mkdir -p /etc/modules-load.d
      if grep -qxF 8021q /etc/modules-load.d/8021q.conf 2>/dev/null; then
        log_skip "8021q module autoload already configured"
      else
        printf '8021q\n' > /etc/modules-load.d/8021q.conf
        log_ok "8021q module autoload configured"
      fi
      ;;
    *) log_skip "No VLAN interfaces in config" ;;
  esac
}

configure_network_interfaces() {
  if [ ! -d /etc/network ]; then
    log_warn "/etc/network not found. This host may use NetworkManager or systemd-networkd."
    return 0
  fi
  configure_vlan_support
  local tmp
  tmp="$(mktemp)"
  render_interfaces_file "$tmp"
  if [ -f /etc/network/interfaces ] && cmp -s "$tmp" /etc/network/interfaces; then
    rm -f "$tmp"
    log_skip "/etc/network/interfaces already matches config"
    return 0
  fi
  backup_file /etc/network/interfaces
  cp "$tmp" /etc/network/interfaces
  rm -f "$tmp"
  log_ok "/etc/network/interfaces rendered"
  log_warn "Network restart is not forced. Reboot or restart networking during a maintenance window."
}

set_ip_forward() {
  local desired="$1"
  local conf="/etc/sysctl.d/99-demo-autoconfig.conf"
  if [ "$desired" != "yes" ]; then
    log_skip "IP forwarding disabled by config"
    return 0
  fi
  if grep -q '^net.ipv4.ip_forward=1$' "$conf" 2>/dev/null; then
    log_skip "IP forwarding sysctl already configured"
  else
    backup_file "$conf"
    printf 'net.ipv4.ip_forward=1\n' > "$conf"
    log_ok "IP forwarding sysctl configured"
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

ensure_iptables_rule() {
  local table="$1"; shift
  if /usr/sbin/iptables -t "$table" -C "$@" 2>/dev/null; then
    log_skip "iptables rule exists: -t $table $*"
  else
    /usr/sbin/iptables -t "$table" -A "$@"
    log_ok "iptables rule added: -t $table $*"
  fi
}

save_iptables_rules() {
  mkdir -p /etc/demo-autoconfig
  /usr/sbin/iptables-save > /etc/demo-autoconfig/iptables.rules
  if command_exists netfilter-persistent; then
    netfilter-persistent save || log_warn "netfilter-persistent save failed"
  else
    log_warn "netfilter-persistent not installed. Rules saved to /etc/demo-autoconfig/iptables.rules"
  fi
}

configure_nat() {
  [ "${NAT_ENABLE:-no}" = "yes" ] || { log_skip "NAT disabled by config"; return 0; }
  if [ ! -x /usr/sbin/iptables ]; then
    install_packages iptables iptables-persistent || true
  fi
  [ -x /usr/sbin/iptables ] || { log_error "/usr/sbin/iptables not found. Install package: iptables"; return 1; }
  if [ -z "${NAT_OUT_IFACE:-}" ] || [ -z "${NAT_LAN_CIDRS:-}" ]; then
    log_warn "NAT_OUT_IFACE or NAT_LAN_CIDRS is empty. NAT skipped."
    return 0
  fi
  local cidr
  for cidr in $NAT_LAN_CIDRS; do
    ensure_iptables_rule nat POSTROUTING -s "$cidr" -o "$NAT_OUT_IFACE" -j MASQUERADE
  done
  save_iptables_rules
}

configure_static_routes() {
  local route
  for route in ${STATIC_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    local args
    args=("$ROUTE_DEST" via "$ROUTE_VIA")
    [ -n "$ROUTE_DEV" ] && args+=(dev "$ROUTE_DEV")
    if ip route show "$ROUTE_DEST" | grep -q "via $ROUTE_VIA"; then
      log_skip "Route exists: $ROUTE_DEST via $ROUTE_VIA"
    else
      ip route replace "${args[@]}"
      log_ok "Route configured: $ROUTE_DEST via $ROUTE_VIA"
    fi
  done
}

configure_gre() {
  [ "${GRE_ENABLE:-no}" = "yes" ] || { log_skip "GRE disabled by config"; return 0; }
  if [ -z "${GRE_LOCAL_IP:-}" ] || [ -z "${GRE_REMOTE_IP:-}" ] || [ -z "${GRE_TUNNEL_LOCAL_CIDR:-}" ]; then
    log_warn "GRE variables are incomplete. GRE skipped."
    return 0
  fi
  if ip link show "$GRE_NAME" >/dev/null 2>&1; then
    log_skip "GRE interface already exists: $GRE_NAME"
  else
    ip tunnel add "$GRE_NAME" mode gre local "$GRE_LOCAL_IP" remote "$GRE_REMOTE_IP" ttl "${GRE_TTL:-255}"
    log_ok "GRE tunnel created: $GRE_NAME"
  fi
  ip addr show "$GRE_NAME" | grep -q "$GRE_TUNNEL_LOCAL_CIDR" || ip addr add "$GRE_TUNNEL_LOCAL_CIDR" dev "$GRE_NAME"
  ip link set "$GRE_NAME" up
  local route
  for route in ${GRE_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    ip route replace "$ROUTE_DEST" via "$ROUTE_VIA"
    log_ok "GRE route configured: $ROUTE_DEST via $ROUTE_VIA"
  done
  log_ok "GRE tunnel is up: $GRE_NAME"
}

configure_frr_ospf() {
  [ "${OSPF_ENABLE:-no}" = "yes" ] || { log_skip "OSPF disabled by config"; return 0; }
  install_packages frr
  backup_file /etc/frr/daemons
  sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
  local conf="/etc/frr/frr.conf"
  backup_file "$conf"
  {
    printf 'frr version 8\nfrr defaults traditional\nhostname %s\nservice integrated-vtysh-config\n!\n' "${HOSTNAME:-router}"
    printf 'ip forwarding\n!\n'
    printf 'router ospf\n'
    [ -n "${OSPF_ROUTER_ID:-}" ] && printf ' ospf router-id %s\n' "$OSPF_ROUTER_ID"
    if [ -n "${OSPF_ACTIVE_IFACES:-}" ]; then
      printf ' passive-interface default\n'
      local active_iface
      for active_iface in ${OSPF_ACTIVE_IFACES:-}; do
        printf ' no passive-interface %s\n' "$active_iface"
      done
    fi
    local net
    for net in ${OSPF_NETWORKS:-}; do
      printf ' network %s area 0\n' "$net"
    done
    printf '!\n'
    if [ -n "${OSPF_AUTH_KEY:-}" ]; then
      local auth_iface
      for auth_iface in ${OSPF_ACTIVE_IFACES:-${GRE_NAME:-}}; do
        [ -z "$auth_iface" ] && continue
        printf 'interface %s\n' "$auth_iface"
        printf ' ip ospf authentication message-digest\n'
        printf ' ip ospf message-digest-key 1 md5 %s\n' "$OSPF_AUTH_KEY"
        printf '!\n'
      done
    fi
  } > "$conf"
  enable_service frr
  restart_service frr
}
