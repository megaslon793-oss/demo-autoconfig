# router_ssh_port_guard_0_6_17
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"
if [ "$SSH_ROUTER_PORT" = "2026" ]; then SSH_ROUTER_PORT="22"; fi

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs

detect_os() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    log_ok "Detected OS: ${PRETTY_NAME:-unknown}"
  else
    log_warn "Cannot detect OS: /etc/os-release not found"
  fi
}

mount_additional_iso() {
  [ -n "${ISO_PATH:-}" ] || { log_skip "ISO path is empty"; return 0; }
  [ -e "$ISO_PATH" ] || { log_warn "ISO path does not exist: $ISO_PATH"; return 0; }
  mkdir -p "${ISO_MOUNTPOINT:-/mnt/additional}"
  if mountpoint -q "${ISO_MOUNTPOINT:-/mnt/additional}"; then
    log_skip "ISO already mounted: ${ISO_MOUNTPOINT:-/mnt/additional}"
  else
    mount -o loop,ro "$ISO_PATH" "${ISO_MOUNTPOINT:-/mnt/additional}" && log_ok "ISO mounted to ${ISO_MOUNTPOINT:-/mnt/additional}"
  fi
}

check_connectivity() {
  local ip
  if [ -n "${DEFAULT_GW:-}" ]; then
    ping -c 1 -W 2 "$DEFAULT_GW" >/dev/null 2>&1 && log_ok "Gateway reachable: $DEFAULT_GW" || log_warn "Gateway is not reachable: $DEFAULT_GW"
  fi
  if [ -n "${INTERNET_TEST_IP:-}" ]; then
    ping -c 1 -W 2 "$INTERNET_TEST_IP" >/dev/null 2>&1 && log_ok "Internet test IP reachable: $INTERNET_TEST_IP" || log_warn "Internet test IP is not reachable: $INTERNET_TEST_IP"
  fi
  for ip in ${NEIGHBOR_IPS:-}; do
    ping -c 1 -W 2 "$ip" >/dev/null 2>&1 && log_ok "Neighbor reachable: $ip" || log_warn "Neighbor is not reachable: $ip"
  done
}

default_hostname_for_role() {
  case "$1" in
    ISP) printf 'isp' ;;
    HQ-RTR) printf 'hq-rtr' ;;
    BR-RTR) printf 'br-rtr' ;;
    HQ-SRV) printf 'hq-srv' ;;
    BR-SRV) printf 'br-srv' ;;
    HQ-CLI) printf 'hq-cli' ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

create_config() {
  local old_role="" old_hostname="" old_domain=""
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    old_role="${ROLE:-}"
    old_hostname="${HOSTNAME:-}"
    old_domain="${DOMAIN:-}"
    if confirm "Existing config found at $CONFIG_FILE. Use it without changes?"; then
      log_ok "Using existing config"
      return 0
    fi
    backup_file "$CONFIG_FILE"
  fi

  prompt_choice ROLE "Device role" ISP HQ-RTR BR-RTR HQ-SRV BR-SRV HQ-CLI
  prompt_default DOMAIN "Domain" "${old_domain:-au-team.irpo}"
  prompt_default HOSTNAME "Hostname (FQDN)" "$(fqdn_hostname "${old_hostname:-$(default_hostname_for_role "$ROLE")}" "$DOMAIN")"
  HOSTNAME="$(fqdn_hostname "$HOSTNAME" "$DOMAIN")"
  prompt_default ISO_PATH "Path to Additional.iso or mounted ISO directory" ""
  prompt_default ISO_MOUNTPOINT "ISO mountpoint" "/mnt/additional"
  prompt_choice LOCK_RESOLV_CONF "Lock /etc/resolv.conf with chattr +i" yes no
  prompt_default NETWORK_APPLY_ACTION "Apply networking at end: restart/reboot/no" "restart"
  prompt_default RESOLV_OPTIONS "resolv.conf options" "timeout:2 attempts:3"

  prompt_default INTERFACES "Interface names separated by spaces" ""
  prompt_default WAN_IFACE "WAN/upstream interface" ""
  prompt_default LAN_IFACE "LAN/downstream interface" ""
  prompt_default MGMT_IFACE "Management interface" ""
  prompt_default INTERNET_IFACE "Extra DHCP Internet interface" ""
  prompt_default INTERNET_IFACE_METRIC "Metric for extra DHCP Internet interface" ""
  prompt_default DEFAULT_GW_METRIC "Metric for lab/default gateway interface" ""
  prompt_default IPV4_CONFIGS "IPv4 configs, format iface:cidr or iface:dhcp, separated by spaces" ""
  prompt_default DEFAULT_GW "Default gateway IP" ""
  prompt_default DNS_SERVERS "DNS servers separated by spaces" ""
  prompt_default HOSTS_ENTRIES "Extra /etc/hosts entries separated by semicolon, format 'IP fqdn short;IP fqdn short'" ""
  prompt_default NEIGHBOR_IPS "Neighbor IPs to ping, separated by spaces" ""
  prompt_default INTERNET_TEST_IP "Internet test IP" "8.8.8.8"

  local ip_forward_default="no"
  case "$ROLE" in ISP|HQ-RTR|BR-RTR) ip_forward_default="yes" ;; esac
  prompt_default IP_FORWARD "Enable IPv4 forwarding: yes/no/auto" "$ip_forward_default"
  prompt_default NAT_ENABLE "Enable NAT on this host: yes/no" "no"
  prompt_default NAT_OUT_IFACE "NAT outside interface" "$WAN_IFACE"
  prompt_default NAT_LAN_CIDRS "NAT source CIDRs separated by spaces" ""
  prompt_default NAT_EXCLUDE_CIDRS "NAT destination CIDRs to exclude from masquerade" ""
  prompt_default STATIC_ROUTES "Static routes, format destination_cidr:gateway, separated by spaces" ""
  prompt_default STATIC_ROUTES_IFACE "Interface where static route hooks are rendered in /etc/network/interfaces" "$WAN_IFACE"

  prompt_default GRE_ENABLE "Enable GRE: yes/no" "no"
  prompt_default GRE_NAME "GRE interface name" "gre1"
  prompt_default GRE_LOCAL_IP "GRE local public/source IP" ""
  prompt_default GRE_REMOTE_IP "GRE remote public/source IP" ""
  prompt_default GRE_TUNNEL_LOCAL_CIDR "GRE local tunnel address CIDR" ""
  prompt_default GRE_TUNNEL_REMOTE_CIDR "GRE remote tunnel address CIDR" ""
  prompt_default GRE_ROUTES "Routes through GRE, format destination_cidr:gateway, separated by spaces" ""
  prompt_default GRE_TTL "GRE TTL" "255"

  prompt_default OSPF_ENABLE "Enable FRR/OSPF: yes/no" "no"
  prompt_default OSPF_ROUTER_ID "OSPF router-id" ""
  prompt_default OSPF_NETWORKS "OSPF networks separated by spaces" ""
  prompt_default OSPF_ACTIVE_IFACES "OSPF non-passive interfaces separated by spaces" "$GRE_NAME"
  prompt_default OSPF_AUTH_KEY "OSPF MD5 key for active interfaces" ""

  prompt_default DHCP_ENABLE "Enable DHCP server: yes/no" "no"
  prompt_default DHCP_IFACE "DHCP listen interface" "$LAN_IFACE"
  prompt_default DHCP_SUBNET "DHCP subnet declaration, example '192.168.10.0 netmask 255.255.255.0'" ""
  prompt_default DHCP_RANGE_START "DHCP range start" ""
  prompt_default DHCP_RANGE_END "DHCP range end" ""
  prompt_default DHCP_OPTION_ROUTERS "DHCP router option" ""
  prompt_default DHCP_OPTION_DNS "DHCP DNS option in dhcpd syntax, example '192.168.10.10, 8.8.8.8'" ""
  prompt_default DHCP_BROADCAST_ADDRESS "DHCP broadcast-address option" ""
  prompt_default DHCP_DOMAIN "DHCP domain" "$DOMAIN"

  prompt_default BIND_ENABLE "Enable bind9 base install on this host: yes/no" "no"
  prompt_default BIND_ZONES "DNS zones to create later, separated by spaces" ""

  prompt_default SSH_HARDENING "Apply SSH hardening: yes/no" "yes"
  prompt_default SSH_PORT "SSH port" "22"
  prompt_default SSH_PERMIT_ROOT_LOGIN "SSH PermitRootLogin value" "prohibit-password"
  prompt_default SSH_PASSWORD_AUTHENTICATION "SSH PasswordAuthentication value" "yes"
  prompt_default SSH_MAX_AUTH_TRIES "SSH MaxAuthTries value" ""
  prompt_default SSH_ALLOW_USERS "SSH AllowUsers value" ""
  prompt_default SSH_BANNER_TEXT "SSH banner text" ""
  prompt_default SSH_USER "Managed SSH user for server roles" "sshuser"
  prompt_default SSH_USER_UID "Managed SSH user UID" "2026"
  prompt_default SSH_PASSWORD "Managed SSH user password" "P@ssw0rd"
  prompt_default SSH_REMOTE_USER "Regular server user" "user"
  prompt_default SSH_SERVER_PORT "Server SSH port" "2026"
  prompt_default SSH_ROUTER_USER "Managed SSH user for router roles" "net_admin"
  prompt_default SSH_ROUTER_PASSWORD "Managed router SSH user password" "P@ssw0rd"
  prompt_default SSH_ROUTER_EXTRA_USER "Regular router user" "user"
  prompt_default SSH_ROUTER_PORT "Router SSH port" "22"
  prompt_default SSH_CLIENT_CONFIG "Write client aliases hq-srv/br-srv: yes/no" "no"
  prompt_default ADMIN_PASSWORD "Module 2 admin password" "${SSH_PASSWORD:-P@ssw0rd}"
  prompt_default DOCKER_DB_NAME "Module 2 Docker DB name" "testdb"
  prompt_default DOCKER_DB_USER "Module 2 Docker DB user" "test"
  prompt_default DOCKER_DB_PASSWORD "Module 2 Docker DB password" "$ADMIN_PASSWORD"
  prompt_default DOCKER_DB_ROOT_PASSWORD "Module 2 Docker DB root password" "root$ADMIN_PASSWORD"
  prompt_default HQ_CLI_ANSIBLE_USER "HQ-CLI Ansible user" "user"
  prompt_default HQ_CLI_ANSIBLE_PASSWORD "HQ-CLI Ansible password, empty if not managed by script" ""
  prompt_default YANDEX_BROWSER_ENABLE "Install Yandex Browser on HQ-CLI: yes/no" "yes"

  validate_role "$ROLE"
  local iface
  for iface in $INTERFACES $WAN_IFACE $LAN_IFACE $MGMT_IFACE; do
    validate_interface_exists "$iface"
  done

  HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
  HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-192.168.100.1}"
  HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
  BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
  BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
  BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
  HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
  HQ_CLI_NET="${HQ_CLI_NET:-192.168.200.0/27}"
  NTP_SERVER_IP="${NTP_SERVER_IP:-172.16.1.1}"
  NFS_DIR="${NFS_DIR:-/raid/nfs}"
  SAMBA_DOMAIN="${SAMBA_DOMAIN:-AU-TEAM}"
  SAMBA_DNS_FORWARDER="${SAMBA_DNS_FORWARDER:-8.8.8.8}"
  DOCKER_SITE_IMAGE="${DOCKER_SITE_IMAGE:-site:latest}"
  DOCKER_DB_IMAGE="${DOCKER_DB_IMAGE:-mariadb:10.11}"
  DOCKER_SITE_TAR="${DOCKER_SITE_TAR:-docker/site_latest.tar}"
  DOCKER_DB_TAR="${DOCKER_DB_TAR:-docker/mariadb_latest.tar}"
  USERS_CSV_PATH="${USERS_CSV_PATH:-Users.csv}"
  MODULE2_CREATE_RAID="${MODULE2_CREATE_RAID:-yes}"
  HQ_CLI_ANSIBLE_PORT="${HQ_CLI_ANSIBLE_PORT:-22}"

  write_kv_config "$CONFIG_FILE" \
    ROLE "$ROLE" HOSTNAME "$HOSTNAME" DOMAIN "$DOMAIN" \
    ISO_PATH "$ISO_PATH" ISO_MOUNTPOINT "$ISO_MOUNTPOINT" LOCK_RESOLV_CONF "$LOCK_RESOLV_CONF" NETWORK_APPLY_ACTION "$NETWORK_APPLY_ACTION" RESOLV_OPTIONS "$RESOLV_OPTIONS" \
    INTERFACES "$INTERFACES" WAN_IFACE "$WAN_IFACE" LAN_IFACE "$LAN_IFACE" MGMT_IFACE "$MGMT_IFACE" INTERNET_IFACE "$INTERNET_IFACE" INTERNET_IFACE_METRIC "$INTERNET_IFACE_METRIC" DEFAULT_GW_METRIC "$DEFAULT_GW_METRIC" \
    IPV4_CONFIGS "$IPV4_CONFIGS" DEFAULT_GW "$DEFAULT_GW" DNS_SERVERS "$DNS_SERVERS" HOSTS_ENTRIES "$HOSTS_ENTRIES" \
    NEIGHBOR_IPS "$NEIGHBOR_IPS" INTERNET_TEST_IP "$INTERNET_TEST_IP" \
    ROUTER_ROLES "ISP HQ-RTR BR-RTR" IP_FORWARD "$IP_FORWARD" NAT_ENABLE "$NAT_ENABLE" NAT_OUT_IFACE "$NAT_OUT_IFACE" NAT_LAN_CIDRS "$NAT_LAN_CIDRS" NAT_EXCLUDE_CIDRS "$NAT_EXCLUDE_CIDRS" STATIC_ROUTES "$STATIC_ROUTES" STATIC_ROUTES_IFACE "$STATIC_ROUTES_IFACE" \
    GRE_ENABLE "$GRE_ENABLE" GRE_NAME "$GRE_NAME" GRE_LOCAL_IP "$GRE_LOCAL_IP" GRE_REMOTE_IP "$GRE_REMOTE_IP" GRE_TUNNEL_LOCAL_CIDR "$GRE_TUNNEL_LOCAL_CIDR" GRE_TUNNEL_REMOTE_CIDR "$GRE_TUNNEL_REMOTE_CIDR" GRE_ROUTES "$GRE_ROUTES" GRE_TTL "$GRE_TTL" \
    OSPF_ENABLE "$OSPF_ENABLE" OSPF_ROUTER_ID "$OSPF_ROUTER_ID" OSPF_NETWORKS "$OSPF_NETWORKS" OSPF_ACTIVE_IFACES "$OSPF_ACTIVE_IFACES" OSPF_AUTH_KEY "$OSPF_AUTH_KEY" \
    DHCP_ENABLE "$DHCP_ENABLE" DHCP_IFACE "$DHCP_IFACE" DHCP_SUBNET "$DHCP_SUBNET" DHCP_RANGE_START "$DHCP_RANGE_START" DHCP_RANGE_END "$DHCP_RANGE_END" DHCP_OPTION_ROUTERS "$DHCP_OPTION_ROUTERS" DHCP_OPTION_DNS "$DHCP_OPTION_DNS" DHCP_BROADCAST_ADDRESS "$DHCP_BROADCAST_ADDRESS" DHCP_DOMAIN "$DHCP_DOMAIN" \
    BIND_ENABLE "$BIND_ENABLE" BIND_ZONES "$BIND_ZONES" \
    SSH_HARDENING "$SSH_HARDENING" SSH_PORT "$SSH_PORT" SSH_PERMIT_ROOT_LOGIN "$SSH_PERMIT_ROOT_LOGIN" SSH_PASSWORD_AUTHENTICATION "$SSH_PASSWORD_AUTHENTICATION" SSH_MAX_AUTH_TRIES "$SSH_MAX_AUTH_TRIES" \
    SSH_ALLOW_USERS "$SSH_ALLOW_USERS" SSH_BANNER_TEXT "$SSH_BANNER_TEXT" SSH_USER "$SSH_USER" SSH_USER_UID "$SSH_USER_UID" SSH_PASSWORD "$SSH_PASSWORD" SSH_REMOTE_USER "$SSH_REMOTE_USER" SSH_SERVER_PORT "$SSH_SERVER_PORT" \
    SSH_ROUTER_USER "$SSH_ROUTER_USER" SSH_ROUTER_PASSWORD "$SSH_ROUTER_PASSWORD" SSH_ROUTER_EXTRA_USER "$SSH_ROUTER_EXTRA_USER" SSH_ROUTER_PORT "$SSH_ROUTER_PORT" SSH_CLIENT_CONFIG "$SSH_CLIENT_CONFIG" \
    ADMIN_PASSWORD "$ADMIN_PASSWORD" DOCKER_DB_NAME "$DOCKER_DB_NAME" DOCKER_DB_USER "$DOCKER_DB_USER" DOCKER_DB_PASSWORD "$DOCKER_DB_PASSWORD" DOCKER_DB_ROOT_PASSWORD "$DOCKER_DB_ROOT_PASSWORD" \
    HQ_SRV_IP "$HQ_SRV_IP" HQ_RTR_HQ_IP "$HQ_RTR_HQ_IP" HQ_RTR_WAN_IP "$HQ_RTR_WAN_IP" BR_RTR_WAN_IP "$BR_RTR_WAN_IP" BR_RTR_LAN_IP "$BR_RTR_LAN_IP" BR_SRV_IP "$BR_SRV_IP" HQ_CLI_IP "$HQ_CLI_IP" HQ_CLI_NET "$HQ_CLI_NET" \
    NTP_SERVER_IP "$NTP_SERVER_IP" NFS_DIR "$NFS_DIR" SAMBA_DOMAIN "$SAMBA_DOMAIN" SAMBA_DNS_FORWARDER "$SAMBA_DNS_FORWARDER" \
    DOCKER_SITE_IMAGE "$DOCKER_SITE_IMAGE" DOCKER_DB_IMAGE "$DOCKER_DB_IMAGE" DOCKER_SITE_TAR "$DOCKER_SITE_TAR" DOCKER_DB_TAR "$DOCKER_DB_TAR" USERS_CSV_PATH "$USERS_CSV_PATH" MODULE2_CREATE_RAID "$MODULE2_CREATE_RAID" \
    HQ_CLI_ANSIBLE_USER "$HQ_CLI_ANSIBLE_USER" HQ_CLI_ANSIBLE_PASSWORD "$HQ_CLI_ANSIBLE_PASSWORD" HQ_CLI_ANSIBLE_PORT "$HQ_CLI_ANSIBLE_PORT" YANDEX_BROWSER_ENABLE "$YANDEX_BROWSER_ENABLE"

  log_ok "Config saved: $CONFIG_FILE"
}

main() {
  detect_os
  create_config
  load_config
  set_hostname_idempotent "$HOSTNAME"
  configure_hosts
  configure_resolv_conf
  mount_additional_iso
  check_connectivity
}

main "$@"
