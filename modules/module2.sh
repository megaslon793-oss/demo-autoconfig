#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

ADMIN_PASSWORD="${ADMIN_PASSWORD:-P@ssw0rd}"
DOCKER_DB_NAME="${DOCKER_DB_NAME:-testdb}"
DOCKER_DB_USER="${DOCKER_DB_USER:-test}"
DOCKER_DB_PASSWORD="${DOCKER_DB_PASSWORD:-$ADMIN_PASSWORD}"
DOCKER_DB_ROOT_PASSWORD="${DOCKER_DB_ROOT_PASSWORD:-root$ADMIN_PASSWORD}"
DOMAIN_LOWER="${DOMAIN:-au-team.irpo}"
REALM_UPPER="${REALM_UPPER:-$(printf '%s' "$DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]')}"
SAMBA_DOMAIN="${SAMBA_DOMAIN:-AU-TEAM}"
SAMBA_DNS_FORWARDER="${SAMBA_DNS_FORWARDER:-8.8.8.8}"
HQ_SRV_IP="${HQ_SRV_IP:-}"
HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-}"
HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-}"
BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-}"
BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-}"
BR_SRV_IP="${BR_SRV_IP:-}"
HQ_CLI_IP="${HQ_CLI_IP:-}"
HQ_CLI_NET="${HQ_CLI_NET:-}"
SSH_SERVER_USER="${SSH_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_PASSWORD:-$ADMIN_PASSWORD}"
SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-2026}"
HQ_CLI_ANSIBLE_USER="${HQ_CLI_ANSIBLE_USER:-user}"
HQ_CLI_ANSIBLE_PASSWORD="${HQ_CLI_ANSIBLE_PASSWORD:-root}"
HQ_CLI_ANSIBLE_PORT="${HQ_CLI_ANSIBLE_PORT:-22}"
NFS_DIR="${NFS_DIR:-/raid/nfs}"
NTP_SERVER_IP="${NTP_SERVER_IP:-}"
ISO_DIR="${ISO_MOUNTPOINT:-/mnt/additional}"
YANDEX_BROWSER_ENABLE="${YANDEX_BROWSER_ENABLE:-yes}"
MODULE2_CREATE_RAID="${MODULE2_CREATE_RAID:-yes}"
DOCKER_SITE_IMAGE="${DOCKER_SITE_IMAGE:-site:latest}"
DOCKER_DB_IMAGE="${DOCKER_DB_IMAGE:-mariadb:10.11}"
DOCKER_DB_TAR="${DOCKER_DB_TAR:-docker/mariadb_latest.tar}"
DOCKER_SITE_TAR="${DOCKER_SITE_TAR:-docker/site_latest.tar}"
USERS_CSV_PATH="${USERS_CSV_PATH:-Users.csv}"
MODULE2_REMOTE_TMP_ROOT="${MODULE2_REMOTE_TMP_ROOT:-/tmp/demo-autoconfig-module2}"
MODULE2_ORCHESTRATE_FROM_ISP="${MODULE2_ORCHESTRATE_FROM_ISP:-auto}"

run_if_needed() {
  local title="$1"
  local check_cmd="$2"
  local action="$3"
  if eval "$check_cmd"; then
    log_skip "$title"
  else
    log_ok "$title"
    eval "$action"
  fi
}

ensure_line() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

ensure_sudoers_file() {
  local file="$1"
  local line="$2"
  printf '%s\n' "$line" > "$file"
  chmod 440 "$file"
  if command_exists visudo; then
    visudo -cf "$file" >/dev/null
  fi
}

ensure_runtime_default() {
  local var_name="$1"
  local fallback="$2"
  if [ -n "${!var_name:-}" ]; then
    return 0
  fi
  printf -v "$var_name" '%s' "$fallback"
  upsert_kv_config "$CONFIG_FILE" "$var_name" "${!var_name}"
  log_warn "$var_name was empty. Using workbook default: ${!var_name}"
}

sed_replacement_escape() {
  printf '%s' "$1" | sed 's/[\\\/&]/\\&/g'
}

php_double_quoted_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g'
}

sql_literal_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_identifier_escape() {
  printf '%s' "$1" | sed 's/`/``/g'
}

service_restart_enable() {
  enable_service "$1"
  restart_service "$1"
}

cidr_ip() {
  printf '%s' "${1%%/*}"
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<EOF
$1
EOF
  printf '%u' "$(((a << 24) + (b << 16) + (c << 8) + d))"
}

int_to_ip() {
  local value="$1"
  printf '%d.%d.%d.%d' \
    "$(((value >> 24) & 255))" \
    "$(((value >> 16) & 255))" \
    "$(((value >> 8) & 255))" \
    "$((value & 255))"
}

cidr_network() {
  local ip="${1%%/*}"
  local prefix="${1#*/}"
  local ip_int mask host_bits
  [ -n "$ip" ] || return 0
  [ "$prefix" != "$1" ] || return 0
  ip_int="$(ip_to_int "$ip")"
  host_bits="$((32 - prefix))"
  if [ "$host_bits" -ge 32 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << host_bits) & 0xFFFFFFFF ))
  fi
  printf '%s/%s' "$(int_to_ip "$((ip_int & mask))")" "$prefix"
}

netmask_to_prefix() {
  local mask="$1" prefix=0 octet bits
  local IFS=.
  for octet in $mask; do
    case "$octet" in
      255) bits=8 ;;
      254) bits=7 ;;
      252) bits=6 ;;
      248) bits=5 ;;
      240) bits=4 ;;
      224) bits=3 ;;
      192) bits=2 ;;
      128) bits=1 ;;
      0) bits=0 ;;
      *) return 1 ;;
    esac
    prefix=$((prefix + bits))
  done
  printf '%s' "$prefix"
}

subnet_decl_to_cidr() {
  local network netmask prefix
  network="$(printf '%s' "$1" | awk '{print $1}')"
  netmask="$(printf '%s' "$1" | awk '{print $3}')"
  [ -n "$network" ] || return 0
  [ -n "$netmask" ] || return 0
  prefix="$(netmask_to_prefix "$netmask" 2>/dev/null || true)"
  [ -n "$prefix" ] || return 0
  printf '%s/%s' "$network" "$prefix"
}

ipv4_config_value_for_iface() {
  local iface="$1" item cfg
  for item in ${IPV4_CONFIGS:-}; do
    [ "${item%%:*}" = "$iface" ] || continue
    cfg="${item#*:}"
    [ "$cfg" != "dhcp" ] && [ "$cfg" != "manual" ] && printf '%s' "$cfg"
    return 0
  done
}

lookup_host_ip() {
  local primary="$1"
  local secondary="${2:-}"
  local entry ip fqdn short
  local old_ifs="$IFS"

  IFS=';'
  for entry in ${HOSTS_ENTRIES:-}; do
    IFS="$old_ifs"
    entry="$(printf '%s' "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$entry" ] || { IFS=';'; continue; }
    set -- $entry
    ip="${1:-}"
    fqdn="${2:-}"
    short="${3:-}"
    if [ "$fqdn" = "$primary" ] || { [ -n "$secondary" ] && [ "$short" = "$secondary" ]; }; then
      printf '%s' "$ip"
      IFS="$old_ifs"
      return 0
    fi
    IFS=';'
  done
  IFS="$old_ifs"

  awk -v primary="$primary" -v secondary="$secondary" '
    $2 == primary || (secondary != "" && $3 == secondary) { print $1; exit }
  ' /etc/hosts 2>/dev/null || true
}

infer_module2_defaults() {
  local local_cidr=""

  case "$ROLE" in
    HQ-SRV)
      local_cidr="$(ipv4_config_value_for_iface "${LAN_IFACE:-${WAN_IFACE:-}}")"
      [ -n "$local_cidr" ] && HQ_SRV_IP="${HQ_SRV_IP:-$(cidr_ip "$local_cidr")}"
      ;;
    BR-SRV)
      local_cidr="$(ipv4_config_value_for_iface "${LAN_IFACE:-${WAN_IFACE:-}}")"
      [ -n "$local_cidr" ] && BR_SRV_IP="${BR_SRV_IP:-$(cidr_ip "$local_cidr")}"
      ;;
    HQ-CLI)
      local_cidr="$(ipv4_config_value_for_iface "${LAN_IFACE:-${WAN_IFACE:-}}")"
      if [ -n "$local_cidr" ]; then
        HQ_CLI_IP="${HQ_CLI_IP:-$(cidr_ip "$local_cidr")}"
        HQ_CLI_NET="${HQ_CLI_NET:-$(cidr_network "$local_cidr")}"
      fi
      ;;
  esac

  HQ_SRV_IP="${HQ_SRV_IP:-$(lookup_host_ip "hq-srv.$DOMAIN_LOWER" "hq-srv")}"
  BR_SRV_IP="${BR_SRV_IP:-$(lookup_host_ip "br-srv.$DOMAIN_LOWER" "br-srv")}"
  HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-$(lookup_host_ip "hq-rtr.$DOMAIN_LOWER" "hq-rtr")}"
  BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-$(lookup_host_ip "br-rtr.$DOMAIN_LOWER" "br-rtr")}"
  HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-$(lookup_host_ip "hq-rtr.$DOMAIN_LOWER" "hq-rtr")}"
  BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-$(lookup_host_ip "br-rtr.$DOMAIN_LOWER" "br-rtr")}"
  HQ_CLI_IP="${HQ_CLI_IP:-$(lookup_host_ip "hq-cli.$DOMAIN_LOWER" "hq-cli")}"
  NTP_SERVER_IP="${NTP_SERVER_IP:-$(lookup_host_ip "docker.$DOMAIN_LOWER" "docker")}"

  if [ -z "${HQ_CLI_NET:-}" ] && [ -n "${DHCP_SUBNET:-}" ]; then
    HQ_CLI_NET="$(subnet_decl_to_cidr "$DHCP_SUBNET")"
  fi

  HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
  HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-192.168.100.1}"
  HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
  BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
  BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
  BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
  HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
  HQ_CLI_NET="${HQ_CLI_NET:-192.168.200.0/27}"
  NTP_SERVER_IP="${NTP_SERVER_IP:-172.16.1.1}"
}

wait_for_check() {
  local attempts="$1"
  local delay="$2"
  local command="$3"
  local count
  for count in $(seq 1 "$attempts"); do
    if eval "$command" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

module2_orchestration_enabled() {
  [ "$ROLE" = "ISP" ] || return 1
  [ "${DEMO_SKIP_MODULE2_ORCHESTRATION:-no}" != "yes" ] || return 1
  [ "$MODULE2_ORCHESTRATE_FROM_ISP" != "no" ] || return 1
}

remote_ssh_exec() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"
  shift 4
  SSHPASS="$password" sshpass -e ssh \
    -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 \
    "$user@$host" "$@"
}

resolve_remote_connection() {
  local target_role="$1"
  REMOTE_HOST=""
  REMOTE_USER=""
  REMOTE_PASSWORD=""
  REMOTE_PORT=""

  case "$target_role" in
    HQ-RTR)
      REMOTE_HOST="$HQ_RTR_WAN_IP"
      REMOTE_USER="$SSH_ROUTER_USER"
      REMOTE_PASSWORD="$SSH_ROUTER_PASSWORD"
      REMOTE_PORT="$SSH_ROUTER_PORT"
      ;;
    BR-RTR)
      REMOTE_HOST="$BR_RTR_WAN_IP"
      REMOTE_USER="$SSH_ROUTER_USER"
      REMOTE_PASSWORD="$SSH_ROUTER_PASSWORD"
      REMOTE_PORT="$SSH_ROUTER_PORT"
      ;;
    HQ-SRV)
      REMOTE_HOST="$HQ_SRV_IP"
      REMOTE_USER="$SSH_SERVER_USER"
      REMOTE_PASSWORD="$SSH_SERVER_PASSWORD"
      REMOTE_PORT="$SSH_SERVER_PORT"
      ;;
    BR-SRV)
      REMOTE_HOST="$BR_SRV_IP"
      REMOTE_USER="$SSH_SERVER_USER"
      REMOTE_PASSWORD="$SSH_SERVER_PASSWORD"
      REMOTE_PORT="$SSH_SERVER_PORT"
      ;;
    HQ-CLI)
      REMOTE_HOST="$HQ_CLI_IP"
      REMOTE_USER="$HQ_CLI_ANSIBLE_USER"
      REMOTE_PASSWORD="$HQ_CLI_ANSIBLE_PASSWORD"
      REMOTE_PORT="$HQ_CLI_ANSIBLE_PORT"
      ;;
    *)
      log_error "Unknown remote Module 2 role: $target_role"
      return 1
      ;;
  esac

  if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_PASSWORD" ] || [ -z "$REMOTE_PORT" ]; then
    log_error "Remote connection parameters are incomplete for $target_role"
    return 1
  fi
}

wait_for_remote_ssh() {
  local target_role="$1"
  local attempt
  resolve_remote_connection "$target_role" || return 1

  for attempt in $(seq 1 12); do
    if remote_ssh_exec "$REMOTE_PASSWORD" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST" true >/dev/null 2>&1; then
      log_ok "SSH is reachable for $target_role at $REMOTE_HOST:$REMOTE_PORT"
      return 0
    fi
    sleep 5
  done

  log_error "Could not reach $target_role over SSH at $REMOTE_HOST:$REMOTE_PORT"
  return 1
}

run_remote_module2_role() {
  local target_role="$1"
  local remote_dir remote_cmd

  wait_for_remote_ssh "$target_role" || return 1
  remote_dir="$MODULE2_REMOTE_TMP_ROOT/${target_role,,}"
  remote_cmd="remote_dir='$remote_dir'; rm -rf \"\$remote_dir\"; mkdir -p \"\$remote_dir\"; tar -xzf - -C \"\$remote_dir\" || { rc=\$?; rm -rf \"\$remote_dir\"; exit \$rc; }; rc=0; DEMO_SKIP_MODULE2_ORCHESTRATION=yes bash \"\$remote_dir/modules/module2.sh\" || rc=\$?; rm -rf \"\$remote_dir\"; exit \$rc"

  log_ok "Starting remote Module 2: $target_role"
  tar -C "$PROJECT_DIR" -czf - VERSION lib modules | \
    SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh \
      -p "$REMOTE_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=10 \
      "$REMOTE_USER@$REMOTE_HOST" "$remote_cmd"
  log_ok "Remote Module 2 finished: $target_role"
}

verify_module2_from_hq_cli() {
  local verify_cmd
  wait_for_remote_ssh "HQ-CLI" || return 1
  verify_cmd="curl -fsS -u 'WEB:$ADMIN_PASSWORD' http://web.$DOMAIN_LOWER/ >/dev/null && curl -fsS http://docker.$DOMAIN_LOWER/ >/dev/null"
  if wait_for_check 12 5 "remote_ssh_exec '$REMOTE_PASSWORD' '$REMOTE_PORT' '$REMOTE_USER' '$REMOTE_HOST' \"$verify_cmd\""; then
    log_ok "HQ-CLI verified http://web.$DOMAIN_LOWER/ and http://docker.$DOMAIN_LOWER/"
  else
    log_error "HQ-CLI could not verify both Module 2 web endpoints"
    return 1
  fi
}

orchestrate_module2_from_isp() {
  ensure_runtime_default HQ_CLI_ANSIBLE_USER user
  ensure_runtime_default HQ_CLI_ANSIBLE_PASSWORD root
  ensure_runtime_default HQ_CLI_ANSIBLE_PORT 22
  install_packages sshpass curl

  run_remote_module2_role "BR-SRV"
  run_remote_module2_role "HQ-SRV"
  run_remote_module2_role "HQ-RTR"
  run_remote_module2_role "BR-RTR"
  run_module2_role_actions "ISP"
  run_remote_module2_role "HQ-CLI"
  verify_module2_from_hq_cli

  log_ok "Module 2 orchestration completed from ISP"
}

prepare_iso_mount() {
  local candidate
  for candidate in "$ISO_DIR" /media/cdrom0 /mnt/additional /tmp/additional; do
    [ -d "$candidate" ] || continue
    if [ -d "$candidate/docker" ] || [ -d "$candidate/web" ] || [ -f "$candidate/Users.csv" ] || [ -f "$candidate/$USERS_CSV_PATH" ]; then
      ISO_DIR="$candidate"
      log_ok "Additional files found: $ISO_DIR"
      return 0
    fi
  done
  if [ -n "${ISO_PATH:-}" ] && [ -d "$ISO_PATH" ]; then
    if [ -d "$ISO_PATH/docker" ] || [ -d "$ISO_PATH/web" ] || [ -f "$ISO_PATH/Users.csv" ] || [ -f "$ISO_PATH/$USERS_CSV_PATH" ]; then
      ISO_DIR="$ISO_PATH"
      log_ok "Additional files found: $ISO_DIR"
      return 0
    fi
  fi
  if [ -n "${ISO_PATH:-}" ] && [ -f "$ISO_PATH" ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o loop,ro "$ISO_PATH" "$ISO_DIR" || true
    if [ -d "$ISO_DIR/docker" ] || [ -d "$ISO_DIR/web" ] || [ -f "$ISO_DIR/Users.csv" ] || [ -f "$ISO_DIR/$USERS_CSV_PATH" ]; then
      log_ok "Additional ISO mounted: $ISO_DIR"
      return 0
    fi
  fi
  log_warn "Additional files were not found. Set ISO_PATH or mount the ISO to $ISO_DIR."
  return 1
}

infer_module2_defaults

write_krb5_conf() {
  backup_file /etc/krb5.conf
  cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = $REALM_UPPER
    dns_lookup_kdc = true
    dns_lookup_realm = false

[realms]
    $REALM_UPPER = {
        kdc = br-srv.$DOMAIN_LOWER
        admin_server = br-srv.$DOMAIN_LOWER
    }

[domain_realm]
    .$DOMAIN_LOWER = $REALM_UPPER
    $DOMAIN_LOWER = $REALM_UPPER
EOF
}

setup_chrony_server() {
  install_packages chrony curl
  backup_file /etc/chrony/chrony.conf
  cat > /etc/chrony/chrony.conf <<EOF
server 0.debian.pool.ntp.org iburst
local stratum 5

allow 172.16.0.0/12
allow 192.168.0.0/16
bindaddress 0.0.0.0

driftfile /var/lib/chrony/chrony.drift

log tracking measurements statistics
logdir /var/log/chrony

rtcsync
EOF
  service_restart_enable chrony
}

setup_chrony_client() {
  install_packages chrony curl
  backup_file /etc/chrony/chrony.conf
  cat > /etc/chrony/chrony.conf <<EOF
server $NTP_SERVER_IP iburst

driftfile /var/lib/chrony/chrony.drift

log tracking measurements statistics
logdir /var/log/chrony

rtcsync
EOF
  service_restart_enable chrony
}

setup_isp_proxy() {
  install_packages nginx apache2-utils
  htpasswd -bc /etc/nginx/.htpasswd WEB "$ADMIN_PASSWORD"
  backup_file /etc/nginx/sites-available/reverse_proxy.conf
  cat > /etc/nginx/sites-available/reverse_proxy.conf <<EOF
upstream hq_srv_app { server ${HQ_SRV_IP}:80; }
upstream testapp_app { server ${BR_SRV_IP}:8080; }

server {
    listen 80;
    server_name web.$DOMAIN_LOWER;

    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://hq_srv_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen 80;
    server_name docker.$DOMAIN_LOWER;

    location / {
        proxy_pass http://testapp_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/reverse_proxy.conf /etc/nginx/sites-enabled/reverse_proxy.conf
  rm -f /etc/nginx/sites-enabled/web.conf /etc/nginx/sites-enabled/docker.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  service_restart_enable nginx
  if wait_for_check 12 5 "curl -fsS -u 'WEB:$ADMIN_PASSWORD' -H 'Host: web.$DOMAIN_LOWER' http://127.0.0.1/"; then
    log_ok "Reverse proxy answers for web.$DOMAIN_LOWER"
  else
    log_warn "Reverse proxy did not answer for web.$DOMAIN_LOWER yet"
  fi
  if wait_for_check 12 5 "curl -fsS -H 'Host: docker.$DOMAIN_LOWER' http://127.0.0.1/"; then
    log_ok "Reverse proxy answers for docker.$DOMAIN_LOWER"
  else
    log_warn "Reverse proxy did not answer for docker.$DOMAIN_LOWER yet"
  fi
}

setup_router_dnat() {
  local dest="$1"
  local wan_ip="$2"
  local wan_iface="${3:-}"
  local prerouting_match=()
  ensure_iptables_available
  [ -n "$wan_iface" ] && prerouting_match+=(-i "$wan_iface")
  [ -n "$wan_ip" ] && prerouting_match+=(-d "$wan_ip")
  ensure_iptables_rule nat PREROUTING "${prerouting_match[@]}" -p tcp --dport 8080 -j DNAT --to-destination "$dest:8080"
  ensure_iptables_rule nat PREROUTING "${prerouting_match[@]}" -p udp --dport 8080 -j DNAT --to-destination "$dest:8080"
  ensure_iptables_rule nat PREROUTING "${prerouting_match[@]}" -p tcp --dport 80 -j DNAT --to-destination "$dest:80"
  ensure_iptables_rule nat PREROUTING "${prerouting_match[@]}" -p tcp --dport 2026 -j DNAT --to-destination "$dest:2026"
  ensure_iptables_rule nat PREROUTING "${prerouting_match[@]}" -p udp --dport 2026 -j DNAT --to-destination "$dest:2026"
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 8080 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p udp -d "$dest" --dport 8080 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 80 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 2026 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p udp -d "$dest" --dport 2026 -j ACCEPT
  save_iptables_rules
}

setup_bind_ad_records() {
  local zone_file="/etc/bind/zones/db.$DOMAIN_LOWER"
  [ -f "$zone_file" ] || { log_warn "DNS zone file not found: $zone_file"; return 0; }
  backup_file "$zone_file"
  ensure_line "$zone_file" "_ldap._tcp IN SRV 0 100 389 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos._tcp IN SRV 0 100 88 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos._udp IN SRV 0 100 88 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kpasswd._tcp IN SRV 0 100 464 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kpasswd._udp IN SRV 0 100 464 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_gc._tcp IN SRV 0 100 3268 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_ldap._tcp.dc._msdcs IN SRV 0 100 389 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos IN TXT \"$REALM_UPPER\""
  if command_exists named-checkzone; then
    named-checkzone "$DOMAIN_LOWER" "$zone_file"
  fi
  restart_service_any bind9 named
}

find_blank_disks_for_raid() {
  local root_src root_disk disk children fstype
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  [ -n "$root_disk" ] || root_disk="$(basename "$root_src" | sed -E 's/p?[0-9]+$//')"
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | while read -r disk; do
    [ "$disk" = "$root_disk" ] && continue
    children="$(lsblk -n -o NAME "/dev/$disk" | wc -l)"
    fstype="$(lsblk -dn -o FSTYPE "/dev/$disk" 2>/dev/null || true)"
    [ "$children" -eq 1 ] && [ -z "$fstype" ] && printf '/dev/%s\n' "$disk"
  done
}

setup_raid_mount() {
  install_packages mdadm parted
  if mountpoint -q /raid; then
    log_skip "/raid already mounted"
    return 0
  fi
  mkdir -p /raid
  mapfile -t disks < <(find_blank_disks_for_raid | head -n 2)
  if [ "${#disks[@]}" -lt 2 ]; then
    log_warn "Not enough blank disks for RAID0. /raid will stay as a directory."
    return 0
  fi
  if [ "${MODULE2_CREATE_RAID:-yes}" != "yes" ]; then
    log_warn "Blank disks found but MODULE2_CREATE_RAID is not yes; RAID creation skipped."
    return 0
  fi
  mdadm --create /dev/md0 --level=0 --raid-devices=2 "${disks[0]}" "${disks[1]}" --force
  mkdir -p /etc/mdadm
  mdadm --detail --scan > /etc/mdadm/mdadm.conf
  update-initramfs -u || true
  parted -s /dev/md0 mklabel gpt
  parted -s /dev/md0 mkpart primary ext4 1MiB 100%
  partprobe /dev/md0 || true
  mkfs.ext4 -F /dev/md0p1
  mount /dev/md0p1 /raid
  ensure_line /etc/fstab "/dev/md0p1 /raid ext4 defaults,nofail 0 0"
}

setup_nfs_server() {
  setup_raid_mount
  install_packages nfs-kernel-server
  mkdir -p "$NFS_DIR"
  chown nobody:nogroup "$NFS_DIR" || true
  chmod 0777 "$NFS_DIR"
  backup_file /etc/exports
  grep -vF "$NFS_DIR " /etc/exports 2>/dev/null > /tmp/demo-exports.$$ || true
  printf '%s %s(rw,sync,no_subtree_check)\n' "$NFS_DIR" "$HQ_CLI_NET" >> /tmp/demo-exports.$$
  cp /tmp/demo-exports.$$ /etc/exports
  rm -f /tmp/demo-exports.$$
  exportfs -ra
  service_restart_enable nfs-kernel-server
}

sql_root() {
  if command_exists mariadb; then
    mariadb -u root -e "$1"
  else
    mysql -u root -e "$1"
  fi
}

setup_hq_web() {
  install_packages apache2 mariadb-server php php-mysql php-cli php-gd libapache2-mod-php
  service_restart_enable mariadb
  local admin_sql_password
  admin_sql_password="$(sql_literal_escape "$ADMIN_PASSWORD")"
  sql_root "CREATE DATABASE IF NOT EXISTS webdb;"
  sql_root "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
  sql_root "CREATE USER IF NOT EXISTS 'user'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost'; FLUSH PRIVILEGES;"
  prepare_iso_mount || { log_error "Additional ISO is required for HQ web files"; return 1; }
  [ -d "$ISO_DIR/web" ] || { log_error "Web directory not found in Additional ISO: $ISO_DIR/web"; return 1; }
  [ -f "$ISO_DIR/web/dump.sql" ] && { mariadb -u root webdb < "$ISO_DIR/web/dump.sql" || mysql -u root webdb < "$ISO_DIR/web/dump.sql" || true; }
  [ -f "$ISO_DIR/web/index.php" ] && cp "$ISO_DIR/web/index.php" /var/www/html/index.php
  mkdir -p /var/www/html/images
  [ -f "$ISO_DIR/web/logo.png" ] && cp "$ISO_DIR/web/logo.png" /var/www/html/images/logo.png
  if [ -f /var/www/html/index.php ]; then
    local web_password
    web_password="$(php_double_quoted_escape "$ADMIN_PASSWORD")"
    web_password="$(sed_replacement_escape "$web_password")"
    sed -i 's/\$username *= *"[^"]*"/$username = "web"/' /var/www/html/index.php || true
    sed -i "s/\\\$password *= *\"[^\"]*\"/\\\$password = \"$web_password\"/" /var/www/html/index.php || true
    sed -i 's/$dbname *= *"[^"]*"/$dbname = "webdb"/' /var/www/html/index.php || true
  fi
  rm -f /var/www/html/index.html
  if [ -f /etc/apache2/mods-enabled/dir.conf ]; then
    sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/' /etc/apache2/mods-enabled/dir.conf
  fi
  command_exists a2enmod && a2enmod rewrite >/dev/null 2>&1 || true
  chown -R www-data:www-data /var/www/html
  chmod -R 755 /var/www/html
  service_restart_enable apache2
  if wait_for_check 12 5 "curl -fsS http://127.0.0.1/"; then
    log_ok "Web app answers on HQ-SRV"
  else
    log_warn "Web app did not answer on HQ-SRV yet"
  fi
}

setup_import_users_from_csv() {
  local csv_src=""
  prepare_iso_mount || { log_warn "Additional ISO not available, CSV import skipped"; return 0; }
  for csv_src in \
    "$ISO_DIR/$USERS_CSV_PATH" \
    "$ISO_DIR/Users.csv" \
    /media/cdrom0/Users.csv \
    /mnt/additional/Users.csv
  do
    [ -f "$csv_src" ] && break
  done
  [ -f "$csv_src" ] || { log_skip "Users.csv not found"; return 0; }

  backup_file /opt/import_users.sh
  cat > /opt/import_users.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CSV_FILE="${1:-/media/cdrom0/Users.csv}"
[ -f "$CSV_FILE" ] || exit 1
tail -n +2 "$CSV_FILE" | while IFS=';' read -r first_name last_name role phone ou street zip city country password
do
  username=$(echo "${first_name:0:1}$last_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ' | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null || true)
  username=$(echo "$username" | tr -d '[:punct:]')
  password=$(echo "${password:-}" | tr -d ' ')
  first_name=$(echo "${first_name:-}" | tr -d ' ')
  last_name=$(echo "${last_name:-}" | tr -d ' ')
  city=$(echo "${city:-}" | tr -d ' ')
  [ -n "$username" ] || continue
  [ -n "$password" ] || continue
  samba-tool user show "$username" >/dev/null 2>&1 && { echo "[SKIP] $username"; continue; }
  samba-tool user create "$username" "$password" \
    --given-name="$first_name" \
    --surname="$last_name" \
    --description="$role" \
    --company="$city" || true
done
EOF
  chmod 755 /opt/import_users.sh
  cp "$csv_src" /opt/users.csv
  /opt/import_users.sh /opt/users.csv || log_warn "Users.csv import finished with warnings"
}

setup_samba_dc() {
  install_packages samba winbind libnss-winbind krb5-user smbclient ldb-tools python3-cryptography expect sshpass
  write_krb5_conf
  ensure_line /etc/hosts "$BR_SRV_IP br-srv.$DOMAIN_LOWER br-srv"
  if samba-tool domain info 127.0.0.1 2>/dev/null | grep -qi "$REALM_UPPER"; then
    log_skip "Samba domain already provisioned"
  else
    backup_file /etc/samba/smb.conf
    rm -f /etc/samba/smb.conf
    systemctl disable --now smbd nmbd winbind 2>/dev/null || true
    samba-tool domain provision \
      --use-rfc2307 \
      --realm="$REALM_UPPER" \
      --domain="$SAMBA_DOMAIN" \
      --server-role=dc \
      --dns-backend=SAMBA_INTERNAL \
      --adminpass="$ADMIN_PASSWORD" \
      --option="dns forwarder=$SAMBA_DNS_FORWARDER"
  fi
  rm -f /var/lib/samba/private/krb5.conf
  ln -sf /etc/krb5.conf /var/lib/samba/private/krb5.conf
  systemctl unmask samba-ad-dc 2>/dev/null || true
  systemctl disable --now smbd nmbd winbind 2>/dev/null || true
  enable_service samba-ad-dc
  restart_service samba-ad-dc
  samba-tool user show user1 >/dev/null 2>&1 || samba-tool user create user1 "$ADMIN_PASSWORD"
  samba-tool group addmembers "Domain Admins" user1 2>/dev/null || true
  for user in hquser1 hquser2 hquser3 hquser4 hquser5; do
    samba-tool user show "$user" >/dev/null 2>&1 || samba-tool user create "$user" "$ADMIN_PASSWORD"
  done
  samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq
  for user in hquser1 hquser2 hquser3 hquser4 hquser5; do
    samba-tool group addmembers hq "$user" 2>/dev/null || true
  done
  setup_import_users_from_csv
}

setup_ansible_br_srv() {
  install_packages ansible sshpass
  mkdir -p /etc/ansible
  local hq_cli_inventory
  hq_cli_inventory="hq-cli ansible_host=$HQ_CLI_IP ansible_port=$HQ_CLI_ANSIBLE_PORT ansible_user=$HQ_CLI_ANSIBLE_USER ansible_password=$HQ_CLI_ANSIBLE_PASSWORD ansible_become=false"
  backup_file /etc/ansible/hosts
  cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=$HQ_SRV_IP ansible_port=$SSH_SERVER_PORT ansible_user=$SSH_SERVER_USER ansible_password=$SSH_SERVER_PASSWORD
$hq_cli_inventory

[routers]
hq-rtr ansible_host=$HQ_RTR_HQ_IP ansible_port=$SSH_ROUTER_PORT ansible_user=$SSH_ROUTER_USER ansible_password=$SSH_ROUTER_PASSWORD
br-rtr ansible_host=$BR_RTR_LAN_IP ansible_port=$SSH_ROUTER_PORT ansible_user=$SSH_ROUTER_USER ansible_password=$SSH_ROUTER_PASSWORD

[all:children]
servers
routers

[all:vars]
ansible_become=yes
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no'
EOF
  backup_file /etc/ansible/ansible.cfg
  cat > /etc/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
forks = 10
timeout = 10
interpreter_python = auto
remote_tmp = /tmp/.ansible-${USER}

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
EOF
  mkdir -p /root/.ssh
  if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa </dev/null >/dev/null 2>&1 || true
  fi
}

docker_compose_up() {
  if docker compose version >/dev/null 2>&1; then
    docker compose up -d
  else
    docker-compose up -d
  fi
}

docker_compose_down_reset() {
  if docker compose version >/dev/null 2>&1; then
    docker compose down -v --remove-orphans
  else
    docker-compose down -v --remove-orphans
  fi
}

retag_docker_image_if_needed() {
  local desired="$1"
  local fallback="$2"
  if docker image inspect "$desired" >/dev/null 2>&1; then
    return 0
  fi
  if docker image inspect "$fallback" >/dev/null 2>&1; then
    docker tag "$fallback" "$desired"
  fi
}

require_docker_image() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1 || {
    log_error "Docker image is required but missing: $image"
    return 1
  }
}

ensure_docker_database() {
  local auth=()
  local db_name db_user db_password
  db_name="$(sql_identifier_escape "$DOCKER_DB_NAME")"
  db_user="$(sql_literal_escape "$DOCKER_DB_USER")"
  db_password="$(sql_literal_escape "$DOCKER_DB_PASSWORD")"

  for _ in $(seq 1 24); do
    if docker exec db mariadb -uroot -p"$DOCKER_DB_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
      auth=(-uroot -p"$DOCKER_DB_ROOT_PASSWORD")
      break
    fi
    if docker exec db mariadb -uroot -e "SELECT 1;" >/dev/null 2>&1; then
      auth=(-uroot)
      break
    fi
    sleep 5
  done

  if [ "${#auth[@]}" -eq 0 ]; then
    log_warn "Could not authenticate to MariaDB container to verify application database"
    return 0
  fi

  docker exec db mariadb "${auth[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$db_name\`;"
  docker exec db mariadb "${auth[@]}" -e "CREATE USER IF NOT EXISTS '$db_user'@'%' IDENTIFIED BY '$db_password';"
  docker exec db mariadb "${auth[@]}" -e "ALTER USER '$db_user'@'%' IDENTIFIED BY '$db_password';"
  docker exec db mariadb "${auth[@]}" -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'%'; FLUSH PRIVILEGES;"
}

setup_docker_app_br_srv() {
  install_packages docker.io docker-compose curl
  service_restart_enable docker
  prepare_iso_mount || return 1
  [ -f "$ISO_DIR/$DOCKER_DB_TAR" ] && docker load -i "$ISO_DIR/$DOCKER_DB_TAR"
  [ -f "$ISO_DIR/$DOCKER_SITE_TAR" ] && docker load -i "$ISO_DIR/$DOCKER_SITE_TAR"
  retag_docker_image_if_needed "$DOCKER_DB_IMAGE" mariadb:latest
  require_docker_image "$DOCKER_SITE_IMAGE" || return 1
  require_docker_image "$DOCKER_DB_IMAGE" || return 1
  mkdir -p /opt/testapp
  local reset_volume="no"
  if [ -f /opt/testapp/docker-compose.yml ] && { ! grep -q "DB_USER: \"$DOCKER_DB_USER\"" /opt/testapp/docker-compose.yml || ! grep -q "DB_PASS: \"$DOCKER_DB_PASSWORD\"" /opt/testapp/docker-compose.yml || ! grep -q "MARIADB_ROOT_PASSWORD: \"$DOCKER_DB_ROOT_PASSWORD\"" /opt/testapp/docker-compose.yml; }; then
    reset_volume="yes"
  fi
  backup_file /opt/testapp/docker-compose.yml
  cat > /opt/testapp/docker-compose.yml <<EOF
version: '3.8'
services:
  testapp:
    image: $DOCKER_SITE_IMAGE
    container_name: testapp
    ports:
      - "8080:8000"
    depends_on:
      - db
    environment:
      - DB_HOST=db
      - DB_NAME=$DOCKER_DB_NAME
      - DB_TYPE=maria
      - DB_USER=$DOCKER_DB_USER
      - DB_PASS=$DOCKER_DB_PASSWORD
      - SERVER_PORT=8080
    restart: unless-stopped
  db:
    image: $DOCKER_DB_IMAGE
    container_name: db
    environment:
      - MARIADB_ROOT_PASSWORD=$DOCKER_DB_ROOT_PASSWORD
      - MARIADB_DATABASE=$DOCKER_DB_NAME
      - MARIADB_USER=$DOCKER_DB_USER
      - MARIADB_PASSWORD=$DOCKER_DB_PASSWORD
    volumes:
      - db_data:/var/lib/mysql
    restart: unless-stopped
volumes:
  db_data:
EOF
  cd /opt/testapp
  if [ "$reset_volume" = "yes" ]; then
    log_warn "Docker compose DB settings changed; resetting old testapp volume"
    docker_compose_down_reset || true
  fi
  docker_compose_up
  ensure_docker_database || true
  docker restart db >/dev/null 2>&1 || true
  docker restart testapp >/dev/null 2>&1 || true
  if wait_for_check 24 5 "curl -fsS http://127.0.0.1:8080"; then
    log_ok "Docker app answers on BR-SRV"
  else
    log_warn "Docker app did not answer on http://127.0.0.1:8080 yet"
  fi
}

configure_hq_domain_sudoers() {
  local file="/etc/sudoers.d/hq"
  local commands="/usr/bin/cat, /usr/bin/grep, /usr/bin/id"
  local gid=""
  gid="$(getent group "hq@$DOMAIN_LOWER" 2>/dev/null | cut -d: -f3 || true)"
  [ -n "$gid" ] || gid="$(getent group hq 2>/dev/null | cut -d: -f3 || true)"
  {
    printf '%%hq ALL=(ALL:ALL) NOPASSWD: %s\n' "$commands"
    [ -n "$gid" ] && printf '%%#%s ALL=(ALL:ALL) NOPASSWD: %s\n' "$gid" "$commands"
  } > "$file"
  chmod 440 "$file"
  if command_exists visudo; then
    visudo -cf "$file" >/dev/null
  fi
}

setup_yandex_browser_client() {
  [ "${YANDEX_BROWSER_ENABLE:-yes}" = "yes" ] || { log_skip "Yandex Browser disabled"; return 0; }
  prepare_iso_mount || true
  local local_deb=""
  if [ -d "$ISO_DIR" ]; then
    local_deb="$(find "$ISO_DIR" -maxdepth 3 -type f -iname 'yandex*.deb' 2>/dev/null | head -n 1)"
  fi
  if [ -n "$local_deb" ]; then
    if apt_get_retry install -y "$local_deb"; then
      log_ok "Yandex Browser installed from ISO package"
      return 0
    fi
    dpkg -i "$local_deb" >/dev/null 2>&1 || true
    apt_get_retry install -f -y >/dev/null 2>&1 || true
    if pkg_installed yandex-browser-stable; then
      log_ok "Yandex Browser installed from ISO package"
      return 0
    fi
  fi
  log_skip "Yandex Browser .deb was not found in Additional ISO"
}

setup_hq_cli_domain_nfs() {
  setup_chrony_client
  write_krb5_conf
  printf 'krb5-config krb5-config/default_realm string %s\n' "$REALM_UPPER" | debconf-set-selections 2>/dev/null || true
  printf 'krb5-config krb5-config/kerberos_servers string br-srv.%s\n' "$DOMAIN_LOWER" | debconf-set-selections 2>/dev/null || true
  printf 'krb5-config krb5-config/admin_server string br-srv.%s\n' "$DOMAIN_LOWER" | debconf-set-selections 2>/dev/null || true
  install_packages openssh-server realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin packagekit krb5-user nfs-common oddjob oddjob-mkhomedir dnsutils
  backup_file /etc/resolv.conf
  cat > /etc/resolv.conf <<EOF
search $DOMAIN_LOWER
domain $DOMAIN_LOWER
nameserver $BR_SRV_IP
nameserver $HQ_SRV_IP
EOF
  enable_service_any ssh sshd
  restart_service_any ssh sshd
  realm discover "$DOMAIN_LOWER" >/dev/null 2>&1 || true
  echo "$ADMIN_PASSWORD" | realm join -v --user=Administrator "$DOMAIN_LOWER" || log_warn "realm join failed or already joined"
  enable_service sssd
  restart_service sssd
  kinit Administrator >/dev/null 2>&1 || true
  klist >/dev/null 2>&1 || true
  configure_hq_domain_sudoers
  pam-auth-update --enable mkhomedir --force 2>/dev/null || true
  showmount -e "$HQ_SRV_IP" >/dev/null 2>&1 || true
  mkdir -p /mnt/nfs
  mountpoint -q /mnt/nfs || mount "$HQ_SRV_IP:$NFS_DIR" /mnt/nfs || log_warn "NFS mount failed; fstab still configured"
  ensure_line /etc/fstab "$HQ_SRV_IP:$NFS_DIR /mnt/nfs nfs defaults,_netdev 0 0"
  mount -a >/dev/null 2>&1 || true
  setup_yandex_browser_client
  if wait_for_check 12 5 "curl -fsS -u 'WEB:$ADMIN_PASSWORD' http://web.$DOMAIN_LOWER/"; then
    log_ok "HQ-CLI reaches http://web.$DOMAIN_LOWER/"
  else
    log_warn "HQ-CLI could not reach http://web.$DOMAIN_LOWER/ yet"
  fi
  if wait_for_check 12 5 "curl -fsS http://docker.$DOMAIN_LOWER/"; then
    log_ok "HQ-CLI reaches http://docker.$DOMAIN_LOWER/"
  else
    log_warn "HQ-CLI could not reach http://docker.$DOMAIN_LOWER/ yet"
  fi
}

run_module2_role_actions() {
  local target_role="$1"

  case "$target_role" in
    ISP)
    run_if_needed "ISP chrony server" "systemctl is-active --quiet chrony" setup_chrony_server
    run_if_needed "ISP nginx reverse proxy" "systemctl is-active --quiet nginx && grep -q 'server_name web.$DOMAIN_LOWER;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null && grep -q 'server_name docker.$DOMAIN_LOWER;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null" setup_isp_proxy
    ;;
  HQ-RTR)
    run_if_needed "HQ-RTR DNAT" "iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $HQ_SRV_IP:80' && iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $HQ_SRV_IP:8080'" "setup_router_dnat '$HQ_SRV_IP' '$HQ_RTR_WAN_IP' '${WAN_IFACE:-ens33}'"
    ;;
  BR-RTR)
    run_if_needed "BR-RTR chrony client" "systemctl is-active --quiet chrony" setup_chrony_client
    run_if_needed "BR-RTR DNAT" "iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $BR_SRV_IP:80' && iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $BR_SRV_IP:8080'" "setup_router_dnat '$BR_SRV_IP' '$BR_RTR_WAN_IP' '${WAN_IFACE:-ens33}'"
    ;;
  HQ-SRV)
    run_if_needed "HQ-SRV chrony client" "systemctl is-active --quiet chrony" setup_chrony_client
    run_if_needed "HQ-SRV DNS AD records" "grep -q '_kerberos IN TXT' /etc/bind/zones/db.$DOMAIN_LOWER 2>/dev/null && grep -q '_ldap._tcp.dc._msdcs' /etc/bind/zones/db.$DOMAIN_LOWER 2>/dev/null" setup_bind_ad_records
    run_if_needed "HQ-SRV NFS server" "exportfs -v 2>/dev/null | grep -q '$NFS_DIR'" setup_nfs_server
    run_if_needed "HQ-SRV web app" "systemctl is-active --quiet apache2 && [ -f /var/www/html/index.php ]" setup_hq_web
    ;;
  BR-SRV)
    run_if_needed "BR-SRV chrony client" "systemctl is-active --quiet chrony" setup_chrony_client
    run_if_needed "BR-SRV Samba AD DC" "systemctl is-active --quiet samba-ad-dc && samba-tool domain info 127.0.0.1 2>/dev/null | grep -qi '$REALM_UPPER'" setup_samba_dc
    run_if_needed "BR-SRV Ansible config" "[ -f /etc/ansible/hosts ] && grep -qi 'hq-srv' /etc/ansible/hosts" setup_ansible_br_srv
    run_if_needed "BR-SRV Docker app" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx testapp && grep -q 'DB_USER: \"$DOCKER_DB_USER\"' /opt/testapp/docker-compose.yml 2>/dev/null && grep -q 'DB_PASS: \"$DOCKER_DB_PASSWORD\"' /opt/testapp/docker-compose.yml 2>/dev/null" setup_docker_app_br_srv
    ;;
  HQ-CLI)
    run_if_needed "HQ-CLI domain and NFS client" "realm list 2>/dev/null | grep -qi '$DOMAIN_LOWER' && grep -q '$HQ_SRV_IP:$NFS_DIR' /etc/fstab 2>/dev/null" setup_hq_cli_domain_nfs
    ;;
  *)
    log_skip "No Module 2 actions for role: $target_role"
    ;;
  esac
}

if module2_orchestration_enabled; then
  orchestrate_module2_from_isp
else
  run_module2_role_actions "$ROLE"
fi

log_ok "Module 2 completed for role: $ROLE"
