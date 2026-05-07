#!/usr/bin/env bash

set_hostname_idempotent() {
  local new_hostname="$1"
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
  local fqdn="${HOSTNAME}.${DOMAIN}"
  grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+$fqdn[[:space:]]+$HOSTNAME" /etc/hosts 2>/dev/null || {
    sed -i '/^[[:space:]]*127\.0\.1\.1[[:space:]]/d' /etc/hosts
    printf '127.0.1.1 %s %s\n' "$fqdn" "$HOSTNAME" >> /etc/hosts
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
    printf 'auto lo\niface lo inet loopback\n\n'
    local item iface cfg
    for item in ${IPV4_CONFIGS:-}; do
      iface="${item%%:*}"
      cfg="${item#*:}"
      [ -z "$iface" ] && continue
      printf 'auto %s\n' "$iface"
      if [ "$cfg" = "dhcp" ]; then
        printf 'iface %s inet dhcp\n\n' "$iface"
      elif [ -n "$cfg" ]; then
        printf 'iface %s inet static\n' "$iface"
        printf '    address %s\n' "$cfg"
        if [ "$iface" = "${WAN_IFACE:-}" ] || [ "$iface" = "${LAN_IFACE:-}" ]; then
          [ -n "${DEFAULT_GW:-}" ] && [ "$iface" = "${WAN_IFACE:-}" ] && printf '    gateway %s\n' "$DEFAULT_GW"
        fi
        [ -n "${DNS_SERVERS:-}" ] && printf '    dns-nameservers %s\n' "$DNS_SERVERS"
        printf '\n'
      fi
    done
  } > "$tmp"
}

configure_network_interfaces() {
  if [ ! -d /etc/network ]; then
    log_warn "/etc/network not found. This host may use NetworkManager or systemd-networkd."
    return 0
  fi
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
  [ -x /usr/sbin/iptables ] || { log_error "/usr/sbin/iptables not found"; return 1; }
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
  local route dest via
  for route in ${STATIC_ROUTES:-}; do
    dest="${route%%:*}"
    via="${route#*:}"
    [ -z "$dest" ] || [ -z "$via" ] || [ "$dest" = "$via" ] && continue
    if ip route show "$dest" | grep -q "via $via"; then
      log_skip "Route exists: $dest via $via"
    else
      ip route replace "$dest" via "$via"
      log_ok "Route configured: $dest via $via"
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
    printf 'router ospf\n'
    [ -n "${OSPF_ROUTER_ID:-}" ] && printf ' ospf router-id %s\n' "$OSPF_ROUTER_ID"
    local net
    for net in ${OSPF_NETWORKS:-}; do
      printf ' network %s area 0\n' "$net"
    done
    printf '!\n'
  } > "$conf"
  enable_service frr
  restart_service frr
}
