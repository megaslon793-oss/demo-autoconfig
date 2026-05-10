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

_resolv_nameservers_for_role() {
  local role="${ROLE:-}"
  local hq_dns="${HQ_SRV_IP:-192.168.100.2}"
  local br_dns="${BR_SRV_IP:-192.168.255.2}"
  local external_dns="${EXTERNAL_DNS_SERVERS:-8.8.8.8}"

  case "$role" in
    HQ-SRV|hq-srv)
      # HQ-SRV is the main Bind9 DNS server, so localhost is valid here.
      printf '%s
' "127.0.0.1"
      for dns in $external_dns; do printf '%s
' "$dns"; done
      ;;
    BR-SRV|br-srv)
      # BR-SRV may be Samba DC/DNS. Use localhost only when samba-ad-dc is really active.
      if systemctl is-active --quiet samba-ad-dc 2>/dev/null; then
        printf '%s
' "127.0.0.1"
        printf '%s
' "$hq_dns"
      else
        printf '%s
' "$br_dns"
        printf '%s
' "$hq_dns"
        for dns in $external_dns; do printf '%s
' "$dns"; done
      fi
      ;;
    *)
      # All other nodes must NOT use localhost as DNS.
      printf '%s
' "$hq_dns"
      printf '%s
' "$br_dns"
      for dns in $external_dns; do printf '%s
' "$dns"; done
      ;;
  esac
}

write_resolv_conf_for_role() {
  local target="/etc/resolv.conf"
  local tmp
  tmp="$(mktemp)"

  {
    [ -n "${DOMAIN:-}" ] && printf 'search %s
' "$DOMAIN"
    printf 'options %s
' "${RESOLV_OPTIONS:-timeout:2 attempts:3}"

    local dns seen_dns=" "
    # Role-based DNS first, then optional DNS_SERVERS from config as fallback/extension.
    for dns in $(_resolv_nameservers_for_role) ${DNS_SERVERS:-}; do
      [ -z "$dns" ] && continue
      case "$seen_dns" in
        *" $dns "*) continue ;;
      esac
      printf 'nameserver %s
' "$dns"
      seen_dns="$seen_dns$dns "
    done
  } > "$tmp"

  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log_skip "/etc/resolv.conf already correct for role ${ROLE:-unknown}"
    return 0
  fi

  if [ "${LOCK_RESOLV_CONF:-no}" = "yes" ] && command_exists chattr; then
    chattr -i "$target" 2>/dev/null || true
  fi

  backup_file "$target"
  cat "$tmp" > "$target"
  rm -f "$tmp"

  if [ "${LOCK_RESOLV_CONF:-no}" = "yes" ] && command_exists chattr; then
    chattr +i "$target" || log_warn "Could not lock /etc/resolv.conf with chattr +i"
  fi

  log_ok "/etc/resolv.conf configured for role ${ROLE:-unknown}"
}

configure_resolv_conf() {
  write_resolv_conf_for_role
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
      if [ -n "${INTERNET_IFACE:-}" ] && [ "$iface" = "$INTERNET_IFACE" ] && ! ip link show "$iface" >/dev/null 2>&1; then
        continue
      fi
      printf 'auto %s\n' "$iface"
      if [ "$cfg" = "dhcp" ]; then
        printf 'iface %s inet dhcp\n' "$iface"
        local metric
        metric="$(interface_metric "$iface")"
        [ -n "$metric" ] && printf '    metric %s\n' "$metric"
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
          [ -n "${DEFAULT_GW:-}" ] && [ "$iface" = "${WAN_IFACE:-}" ] && [ -n "${DEFAULT_GW_METRIC:-}" ] && printf '    metric %s\n' "$DEFAULT_GW_METRIC"
        fi
        render_interface_route_hooks "$iface"
        printf '\n'
      fi
    done
    render_gre_interfaces_stanza
  } > "$tmp"
}

interface_metric() {
  local iface="$1"
  if [ -n "${INTERNET_IFACE:-}" ] && [ "$iface" = "$INTERNET_IFACE" ]; then
    printf '%s' "${INTERNET_IFACE_METRIC:-50}"
    return 0
  fi
  if [ -n "${DEFAULT_GW_METRIC:-}" ] && { [ "$iface" = "${WAN_IFACE:-}" ] || [ "$iface" = "${LAN_IFACE:-}" ]; }; then
    printf '%s' "$DEFAULT_GW_METRIC"
  fi
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
  local route
  for route in ${STATIC_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    if [ -n "$ROUTE_DEV" ]; then
      [ "$iface" = "$ROUTE_DEV" ] || continue
    else
      case " $STATIC_ROUTES_IFACE " in
        *" $iface "*) ;;
        *) continue ;;
      esac
    fi
    printf '    up ip route replace %s via %s' "$ROUTE_DEST" "$ROUTE_VIA"
    [ -n "$ROUTE_DEV" ] && printf ' dev %s' "$ROUTE_DEV"
    printf ' || true\n'
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
    printf '    post-up ip route replace %s via %s dev %s || true\n' "$ROUTE_DEST" "$ROUTE_VIA" "${GRE_NAME:-gre30}"
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
  log_ok "/etc/network/interfaces is ready to apply"
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
  if [ -f /etc/sysctl.conf ] && ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
    sed -i 's/^[#[:space:]]*net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf || printf 'net.ipv4.ip_forward=1\n' >> /etc/sysctl.conf
  fi
}

iptables_cmd() {
  if [ -n "${IPTABLES_BIN:-}" ] && [ -x "$IPTABLES_BIN" ]; then
    printf '%s' "$IPTABLES_BIN"
    return 0
  fi
  command -v iptables 2>/dev/null && return 0
  [ -x /usr/sbin/iptables ] && { printf '/usr/sbin/iptables'; return 0; }
  [ -x /sbin/iptables ] && { printf '/sbin/iptables'; return 0; }
  return 1
}

iptables_save_cmd() {
  if [ -n "${IPTABLES_SAVE_BIN:-}" ] && [ -x "$IPTABLES_SAVE_BIN" ]; then
    printf '%s' "$IPTABLES_SAVE_BIN"
    return 0
  fi
  command -v iptables-save 2>/dev/null && return 0
  [ -x /usr/sbin/iptables-save ] && { printf '/usr/sbin/iptables-save'; return 0; }
  [ -x /sbin/iptables-save ] && { printf '/sbin/iptables-save'; return 0; }
  return 1
}

ensure_iptables_available() {
  if command_exists debconf-set-selections; then
    printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | debconf-set-selections 2>/dev/null || true
    printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | debconf-set-selections 2>/dev/null || true
  fi
  if ! IPTABLES_BIN="$(iptables_cmd)"; then
    install_packages iptables || { log_error "Could not install package: iptables"; return 1; }
    IPTABLES_BIN="$(iptables_cmd)" || { log_error "iptables not found after package install"; return 1; }
  fi
  IPTABLES_SAVE_BIN="$(iptables_save_cmd)" || log_warn "iptables-save not found; NAT rules will not be persisted"
  install_packages iptables-persistent netfilter-persistent || log_warn "Persistent iptables packages were not installed; NAT rules still applied for current boot"
  if command_exists systemctl && systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
    enable_service netfilter-persistent || true
  fi
}

ensure_iptables_rule() {
  local table="$1"; shift
  local iptables="${IPTABLES_BIN:-}"
  [ -n "$iptables" ] || { iptables="$(iptables_cmd)" || return 1; }
  if "$iptables" -t "$table" -C "$@" 2>/dev/null; then
    log_skip "iptables rule exists: -t $table $*"
  else
    "$iptables" -t "$table" -A "$@"
    log_ok "iptables rule added: -t $table $*"
  fi
}

ensure_iptables_insert_rule() {
  local table="$1"; shift
  local chain="$1"; shift
  local iptables="${IPTABLES_BIN:-}"
  [ -n "$iptables" ] || { iptables="$(iptables_cmd)" || return 1; }
  if "$iptables" -t "$table" -C "$chain" "$@" 2>/dev/null; then
    log_skip "iptables rule exists: -t $table $chain $*"
  else
    "$iptables" -t "$table" -I "$chain" 1 "$@"
    log_ok "iptables rule inserted: -t $table $chain $*"
  fi
}

save_iptables_rules() {
  local iptables_save="${IPTABLES_SAVE_BIN:-}"
  [ -n "$iptables_save" ] || iptables_save="$(iptables_save_cmd || true)"
  if [ -z "$iptables_save" ]; then
    log_warn "iptables-save not found. NAT rules are active but not saved."
    return 0
  fi
  mkdir -p /etc/demo-autoconfig /etc/iptables
  "$iptables_save" > /etc/demo-autoconfig/iptables.rules
  "$iptables_save" > /etc/iptables/rules.v4
  if command_exists netfilter-persistent; then
    if command_exists systemctl && systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
      enable_service netfilter-persistent || true
    fi
    netfilter-persistent save || log_warn "netfilter-persistent save failed"
    if command_exists systemctl && systemctl list-unit-files netfilter-persistent.service >/dev/null 2>&1; then
      restart_service netfilter-persistent || log_warn "netfilter-persistent restart failed"
    else
      netfilter-persistent reload || true
    fi
  else
    log_warn "netfilter-persistent not installed. Rules saved to /etc/iptables/rules.v4"
  fi
}

configure_nat() {
  [ "${NAT_ENABLE:-no}" = "yes" ] || { log_skip "NAT disabled by config"; return 0; }
  ensure_iptables_available || return 1
  if [ -z "${NAT_OUT_IFACE:-}" ] || [ -z "${NAT_LAN_CIDRS:-}" ]; then
    log_warn "NAT_OUT_IFACE or NAT_LAN_CIDRS is empty. NAT skipped."
    return 0
  fi
  local nat_lan_cidrs="$NAT_LAN_CIDRS"
  if [ "${ROLE:-}" = "ISP" ]; then
    case " $nat_lan_cidrs " in
      *" 172.16.0.0/16 "*) ;;
      *) nat_lan_cidrs="172.16.0.0/16 $nat_lan_cidrs" ;;
    esac
  fi
  local cidr
  local exclude
  ensure_iptables_rule filter FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  for cidr in $nat_lan_cidrs; do
    for exclude in ${NAT_EXCLUDE_CIDRS:-}; do
      ensure_iptables_insert_rule nat POSTROUTING -s "$cidr" -d "$exclude" -j RETURN
    done
    ensure_iptables_rule filter FORWARD -s "$cidr" -o "$NAT_OUT_IFACE" -j ACCEPT
    ensure_iptables_rule nat POSTROUTING -s "$cidr" -o "$NAT_OUT_IFACE" -j MASQUERADE
  done
  save_iptables_rules
}

ensure_default_route() {
  [ -n "${DEFAULT_GW:-}" ] || return 0
  local iface="${WAN_IFACE:-${LAN_IFACE:-}}"
  [ -n "$iface" ] || return 0
  if ! ip link show "$iface" >/dev/null 2>&1; then
    log_warn "Default route interface is absent: $iface"
    return 0
  fi
  local metric_args=()
  [ -n "${DEFAULT_GW_METRIC:-}" ] && metric_args=(metric "$DEFAULT_GW_METRIC")
  if ip route show default | grep -q "via $DEFAULT_GW"; then
    log_skip "Default route exists: $DEFAULT_GW"
  elif ip route replace default via "$DEFAULT_GW" dev "$iface" "${metric_args[@]}"; then
    log_ok "Default route configured: $DEFAULT_GW dev $iface"
  else
    log_warn "Default route not ready: $DEFAULT_GW dev $iface"
  fi
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
      if ip route replace "${args[@]}"; then
        log_ok "Route configured: $ROUTE_DEST via $ROUTE_VIA"
      else
        log_warn "Route not ready yet: $ROUTE_DEST via $ROUTE_VIA"
      fi
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
    if ip tunnel add "$GRE_NAME" mode gre local "$GRE_LOCAL_IP" remote "$GRE_REMOTE_IP" ttl "${GRE_TTL:-255}"; then
      log_ok "GRE tunnel created: $GRE_NAME"
    else
      log_warn "GRE tunnel not ready yet: $GRE_NAME"
      return 0
    fi
  fi
  ip addr show "$GRE_NAME" | grep -q "$GRE_TUNNEL_LOCAL_CIDR" || ip addr add "$GRE_TUNNEL_LOCAL_CIDR" dev "$GRE_NAME" || log_warn "Could not assign GRE address: $GRE_TUNNEL_LOCAL_CIDR"
  ip link set "$GRE_NAME" up || log_warn "Could not bring GRE up: $GRE_NAME"
  local route
  for route in ${GRE_ROUTES:-}; do
    route_parts "$route"
    [ -z "$ROUTE_DEST" ] || [ -z "$ROUTE_VIA" ] || [ "$ROUTE_DEST" = "$ROUTE_VIA" ] && continue
    if ip route replace "$ROUTE_DEST" via "$ROUTE_VIA" dev "$GRE_NAME"; then
      log_ok "GRE route configured: $ROUTE_DEST via $ROUTE_VIA"
    else
      log_warn "GRE route not ready yet: $ROUTE_DEST via $ROUTE_VIA"
    fi
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
