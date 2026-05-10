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
SSH_REMOTE_USER="${SSH_REMOTE_USER:-user}"
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
  NTP_SERVER_IP="${NTP_SERVER_IP:-${ISP_HQ_IP:-172.16.1.1}}"

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

normalize_module2_defaults() {
  if [ -n "${BIND_FORWARD_RECORDS:-}" ] && printf '%s' "$BIND_FORWARD_RECORDS" | grep -q 'web:172\.16\.2\.1'; then
    BIND_FORWARD_RECORDS="$(printf '%s' "$BIND_FORWARD_RECORDS" | sed 's/web:172\.16\.2\.1/web:172.16.1.1/g')"
    upsert_kv_config "$CONFIG_FILE" BIND_FORWARD_RECORDS "$BIND_FORWARD_RECORDS"
    log_warn "Normalized legacy workbook default for web.$DOMAIN_LOWER to 172.16.1.1"
  fi
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

remote_root_ready() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"
  remote_ssh_exec "$password" "$port" "$user" "$host" "if [ \"\$(id -u)\" -eq 0 ]; then exit 0; elif sudo -n true >/dev/null 2>&1; then exit 0; else printf '%s\n' '$password' | sudo -S -p '' true >/dev/null 2>&1; fi" >/dev/null 2>&1
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

try_connection_candidate() {
  local target_role="$1"
  local host="$2"
  local user="$3"
  local password="$4"
  local port="$5"

  [ -n "$host" ] || return 1
  [ -n "$user" ] || return 1
  [ -n "$password" ] || return 1
  [ -n "$port" ] || return 1

  if remote_root_ready "$password" "$port" "$user" "$host"; then
    REMOTE_HOST="$host"
    REMOTE_USER="$user"
    REMOTE_PASSWORD="$password"
    REMOTE_PORT="$port"
    log_ok "Remote root-capable SSH is reachable for $target_role at $REMOTE_HOST:$REMOTE_PORT as $REMOTE_USER"
    return 0
  fi
  return 1
}

resolve_hq_cli_connection() {
  local pw

  for pw in \
    "${HQ_CLI_ANSIBLE_PASSWORD:-}" \
    "${ADMIN_PASSWORD:-}" \
    "${SSH_PASSWORD:-}" \
    root
  do
    try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" root "$pw" 22 && return 0
    try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" root "$pw" "$SSH_SERVER_PORT" && return 0
  done

  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$HQ_CLI_ANSIBLE_USER" "$HQ_CLI_ANSIBLE_PASSWORD" "$HQ_CLI_ANSIBLE_PORT" && return 0
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$SSH_SERVER_USER" "$SSH_SERVER_PASSWORD" 22 && return 0
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$SSH_SERVER_USER" "$SSH_SERVER_PASSWORD" "$SSH_SERVER_PORT" && return 0
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$SSH_REMOTE_USER" "${SSH_SERVER_PASSWORD:-$ADMIN_PASSWORD}" 22 && return 0
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$SSH_REMOTE_USER" "${HQ_CLI_ANSIBLE_PASSWORD:-$ADMIN_PASSWORD}" 22 && return 0

  return 1
}

resolve_router_connection() {
  local target_role="$1"
  local host="$2"
  local pw

  try_connection_candidate "$target_role" "$host" "$SSH_ROUTER_USER" "$SSH_ROUTER_PASSWORD" "$SSH_ROUTER_PORT" && return 0
  try_connection_candidate "$target_role" "$host" "${SSH_ROUTER_EXTRA_USER:-user}" "${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}" "$SSH_ROUTER_PORT" && return 0

  for pw in \
    "${SSH_ROUTER_PASSWORD:-}" \
    "${ADMIN_PASSWORD:-}" \
    root
  do
    try_connection_candidate "$target_role" "$host" root "$pw" 22 && return 0
    try_connection_candidate "$target_role" "$host" root "$pw" "$SSH_ROUTER_PORT" && return 0
  done

  return 1
}

resolve_server_connection() {
  local target_role="$1"
  local host="$2"
  local pw

  try_connection_candidate "$target_role" "$host" "$SSH_SERVER_USER" "$SSH_SERVER_PASSWORD" "$SSH_SERVER_PORT" && return 0
  try_connection_candidate "$target_role" "$host" "${SSH_REMOTE_USER:-user}" "${SSH_SERVER_PASSWORD:-$ADMIN_PASSWORD}" "$SSH_SERVER_PORT" && return 0

  for pw in \
    "${SSH_SERVER_PASSWORD:-}" \
    "${ADMIN_PASSWORD:-}" \
    root
  do
    try_connection_candidate "$target_role" "$host" root "$pw" 22 && return 0
    try_connection_candidate "$target_role" "$host" root "$pw" "$SSH_SERVER_PORT" && return 0
  done

  return 1
}

wait_for_remote_ssh() {
  local target_role="$1"
  local max_attempts="${2:-}"
  local delay="${3:-3}"
  local quiet="${4:-no}"
  local attempt

  if [ -z "$max_attempts" ]; then
    case "$target_role" in
      HQ-SRV|BR-SRV) max_attempts=4 ;;
      HQ-RTR|BR-RTR|HQ-CLI) max_attempts=2 ;;
      *) max_attempts=4 ;;
    esac
  fi

  if [ "$target_role" = "HQ-CLI" ]; then
    for attempt in $(seq 1 "$max_attempts"); do
      if resolve_hq_cli_connection; then
        return 0
      fi
      sleep "$delay"
    done
    [ "$quiet" = "yes" ] || log_error "Could not find root-capable SSH access for HQ-CLI"
    return 1
  fi

  if [ "$target_role" = "HQ-RTR" ]; then
    for attempt in $(seq 1 "$max_attempts"); do
      if resolve_router_connection "$target_role" "$HQ_RTR_WAN_IP"; then
        return 0
      fi
      sleep "$delay"
    done
    [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH"
    return 1
  fi

  if [ "$target_role" = "BR-RTR" ]; then
    for attempt in $(seq 1 "$max_attempts"); do
      if resolve_router_connection "$target_role" "$BR_RTR_WAN_IP"; then
        return 0
      fi
      sleep "$delay"
    done
    [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH"
    return 1
  fi

  if [ "$target_role" = "HQ-SRV" ]; then
    for attempt in $(seq 1 "$max_attempts"); do
      if resolve_server_connection "$target_role" "$HQ_SRV_IP"; then
        return 0
      fi
      sleep "$delay"
    done
    [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH"
    return 1
  fi

  if [ "$target_role" = "BR-SRV" ]; then
    for attempt in $(seq 1 "$max_attempts"); do
      if resolve_server_connection "$target_role" "$BR_SRV_IP"; then
        return 0
      fi
      sleep "$delay"
    done
    [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH"
    return 1
  fi

  resolve_remote_connection "$target_role" || return 1
  for attempt in $(seq 1 "$max_attempts"); do
    if remote_root_ready "$REMOTE_PASSWORD" "$REMOTE_PORT" "$REMOTE_USER" "$REMOTE_HOST"; then
      log_ok "Remote root-capable SSH is reachable for $target_role at $REMOTE_HOST:$REMOTE_PORT"
      return 0
    fi
    sleep "$delay"
  done

  [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH at $REMOTE_HOST:$REMOTE_PORT"
  return 1
}

stream_remote_module2_role() {
  local target_role="$1"
  local remote_dir remote_cmd remote_pw_q remote_dir_q
  remote_dir="$MODULE2_REMOTE_TMP_ROOT/${target_role,,}"
  printf -v remote_pw_q '%q' "$REMOTE_PASSWORD"
  printf -v remote_dir_q '%q' "$remote_dir"
  remote_cmd="remote_dir=$remote_dir_q; sudo_pw=$remote_pw_q; rm -rf \"\$remote_dir\"; mkdir -p \"\$remote_dir\"; tar -xzf - -C \"\$remote_dir\" || { rc=\$?; rm -rf \"\$remote_dir\"; exit \$rc; }; rc=0; if [ \"\$(id -u)\" -eq 0 ]; then DEMO_SKIP_MODULE2_ORCHESTRATION=yes bash \"\$remote_dir/modules/module2.sh\" || rc=\$?; elif sudo -n true >/dev/null 2>&1; then sudo -n env DEMO_SKIP_MODULE2_ORCHESTRATION=yes bash \"\$remote_dir/modules/module2.sh\" || rc=\$?; else printf '%s\n' \"\$sudo_pw\" | sudo -S -p '' env DEMO_SKIP_MODULE2_ORCHESTRATION=yes bash \"\$remote_dir/modules/module2.sh\" || rc=\$?; fi; if [ \"\$(id -u)\" -eq 0 ]; then rm -rf \"\$remote_dir\"; elif sudo -n true >/dev/null 2>&1; then sudo -n rm -rf \"\$remote_dir\"; else printf '%s\n' \"\$sudo_pw\" | sudo -S -p '' rm -rf \"\$remote_dir\"; fi; exit \$rc"

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

run_remote_module2_role() {
  local target_role="$1"
  wait_for_remote_ssh "$target_role" || return 1
  stream_remote_module2_role "$target_role"
}

run_remote_module2_role_optional() {
  local target_role="$1"
  if ! wait_for_remote_ssh "$target_role" 2 2 yes; then
    if [ "$target_role" = "HQ-CLI" ]; then
      log_warn "Skipping remote Module 2 for HQ-CLI: no root-capable SSH. Run Module 2 locally on HQ-CLI after infrastructure roles finish."
    else
      log_warn "Skipping remote Module 2 for $target_role: no root-capable SSH from ISP"
    fi
    return 0
  fi
  stream_remote_module2_role "$target_role"
}

verify_module2_from_hq_cli() {
  local verify_cmd
  verify_cmd="curl -fsS -u 'WEB:$ADMIN_PASSWORD' http://web.$DOMAIN_LOWER/ >/dev/null && curl -fsS http://docker.$DOMAIN_LOWER/ >/dev/null"
  if wait_for_remote_ssh "HQ-CLI" 2 2 yes; then
    if wait_for_check 12 5 "remote_ssh_exec '$REMOTE_PASSWORD' '$REMOTE_PORT' '$REMOTE_USER' '$REMOTE_HOST' \"$verify_cmd\""; then
      log_ok "HQ-CLI verified http://web.$DOMAIN_LOWER/ and http://docker.$DOMAIN_LOWER/"
      return 0
    fi
    log_error "HQ-CLI could not verify both Module 2 web endpoints"
    return 1
  fi

  log_warn "HQ-CLI root-capable SSH is unavailable. Verifying Module 2 web endpoints from ISP reverse proxy only."
  if wait_for_check 12 5 "curl -fsS -u 'WEB:$ADMIN_PASSWORD' -H 'Host: web.$DOMAIN_LOWER' http://127.0.0.1/ >/dev/null && curl -fsS -H 'Host: docker.$DOMAIN_LOWER' http://127.0.0.1/ >/dev/null"; then
    log_ok "ISP verified reverse proxy for http://web.$DOMAIN_LOWER/ and http://docker.$DOMAIN_LOWER/"
    return 0
  fi

  log_error "Module 2 web endpoints did not answer via ISP reverse proxy"
  return 1
}

run_with_failure_capture() {
  local description="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log_error "$description"
  fi
  return "$rc"
}

orchestrate_module2_from_isp() {
  local failures=0
  ensure_runtime_default HQ_CLI_ANSIBLE_USER user
  ensure_runtime_default HQ_CLI_ANSIBLE_PASSWORD root
  ensure_runtime_default HQ_CLI_ANSIBLE_PORT 22
  install_packages sshpass curl

  run_with_failure_capture "Module 2 role failed: ISP" run_module2_role_actions "ISP" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 role failed: HQ-SRV" run_remote_module2_role "HQ-SRV" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 role failed: BR-SRV" run_remote_module2_role "BR-SRV" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 role failed: HQ-RTR" run_remote_module2_role_optional "HQ-RTR" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 role failed: BR-RTR" run_remote_module2_role_optional "BR-RTR" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 role failed: HQ-CLI" run_remote_module2_role_optional "HQ-CLI" || failures=$((failures + 1))
  run_with_failure_capture "Module 2 endpoint verification failed" verify_module2_from_hq_cli || failures=$((failures + 1))

  if [ "$failures" -gt 0 ]; then
    log_error "Module 2 orchestration completed with $failures failure(s)"
    return 1
  fi

  log_ok "Module 2 orchestration completed from ISP"
}

prepare_iso_mount() {
  local candidate device
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
  for device in /dev/sr0 /dev/cdrom; do
    [ -b "$device" ] || continue
    mkdir -p /mnt/additional
    mountpoint -q /mnt/additional || mount -t iso9660 "$device" /mnt/additional || true
    if [ -d /mnt/additional/docker ] || [ -d /mnt/additional/web ] || [ -f /mnt/additional/Users.csv ] || [ -f /mnt/additional/$USERS_CSV_PATH ]; then
      ISO_DIR="/mnt/additional"
      log_ok "Additional ISO mounted from $device to $ISO_DIR"
      return 0
    fi
  done
  log_warn "Additional files were not found. Set ISO_PATH or mount the ISO to $ISO_DIR."
  return 1
}

prepare_additional_workspace() {
  local source_dir=""
  local workspace="/mnt/additional"
  local staging="$TMP_DIR/additional-source"

  prepare_iso_mount || return 1
  source_dir="$ISO_DIR"

  rm -rf "$staging"
  mkdir -p "$staging"

  if [ "$source_dir" = "$workspace" ] && mountpoint -q "$workspace"; then
    cp -a "$workspace"/. "$staging"/
    umount "$workspace" 2>/dev/null || true
    mkdir -p "$workspace"
    cp -a "$staging"/. "$workspace"/
  else
    mkdir -p "$workspace"
    if [ "$source_dir" != "$workspace" ]; then
      cp -a "$source_dir"/. "$workspace"/
    fi
  fi

  rm -rf "$staging"
  chmod -R 755 "$workspace" 2>/dev/null || true
  ADDITIONAL_WORKDIR="$workspace"
  log_ok "Additional workspace prepared: $ADDITIONAL_WORKDIR"
}

infer_module2_defaults
normalize_module2_defaults

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
  install_packages nginx apache2-utils curl
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

bind_abs_name_m2() {
  local name="$1"
  local zone="$2"
  case "$name" in
    @) printf '%s.' "$zone" ;;
    *.) printf '%s' "$name" ;;
    *.*) printf '%s.' "$name" ;;
    *) printf '%s.%s.' "$name" "$zone" ;;
  esac
}

render_forward_zone_m2() {
  local zone="$1"
  local zone_file="$2"
  local serial="${BIND_ZONE_SERIAL:-2025101302}"
  local ns_name="${BIND_NS_NAME:-ns1}"
  local ns_ip="${BIND_NS_IP:-192.168.100.2}"
  local apex_ip="${BIND_APEX_IP:-$ns_ip}"
  local record name ip

  BIND_FORWARD_RECORDS="${BIND_FORWARD_RECORDS:-hq-rtr:192.168.100.1 br-rtr:192.168.255.1 hq-srv:192.168.100.2 hq-cli:192.168.200.2 br-srv:192.168.255.2 docker:172.16.1.1 web:172.16.1.1}"

  {
    printf '$TTL 3600\n'
    printf '@ IN SOA %s %s (\n' "$(bind_abs_name_m2 "$ns_name" "$zone")" "$(bind_abs_name_m2 "${BIND_ADMIN_NAME:-admin}" "$zone")"
    printf '  %s ; Serial\n' "$serial"
    printf '  3600\n'
    printf '  1800\n'
    printf '  1209600\n'
    printf '  300 )\n\n'
    printf '@ IN NS %s\n' "$(bind_abs_name_m2 "$ns_name" "$zone")"
    printf '%s IN A %s\n\n' "$ns_name" "$ns_ip"
    [ -n "$apex_ip" ] && printf '@ IN A %s\n' "$apex_ip"
    for record in $BIND_FORWARD_RECORDS; do
      name="${record%%:*}"
      ip="${record#*:}"
      [ -n "$name" ] && [ -n "$ip" ] && [ "$name" != "$ip" ] || continue
      [ "$name" = "$ns_name" ] && continue
      printf '%s IN A %s\n' "$name" "$ip"
    done
  } > "$zone_file"
}

setup_bind_ad_records() {
  local zone_file="/etc/bind/zones/db.$DOMAIN_LOWER"
  install_packages bind9 bind9utils bind9-dnsutils || install_packages bind9 bind9utils dnsutils
  mkdir -p /etc/bind/zones
  if [ -f /etc/bind/named.conf.local ] && ! grep -q "zone \"$DOMAIN_LOWER\"" /etc/bind/named.conf.local 2>/dev/null; then
    backup_file /etc/bind/named.conf.local
    cat >> /etc/bind/named.conf.local <<EOF
zone "$DOMAIN_LOWER" {
    type master;
    file "$zone_file";
};

EOF
  fi
  backup_file "$zone_file"
  render_forward_zone_m2 "$DOMAIN_LOWER" "$zone_file"
  ensure_line "$zone_file" "mon IN CNAME hq-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_ldap._tcp IN SRV 0 100 389 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos._tcp IN SRV 0 100 88 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos._udp IN SRV 0 100 88 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kpasswd._tcp IN SRV 0 100 464 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kpasswd._udp IN SRV 0 100 464 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_gc._tcp IN SRV 0 100 3268 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_ldap._tcp.dc._msdcs IN SRV 0 100 389 br-srv.$DOMAIN_LOWER."
  ensure_line "$zone_file" "_kerberos IN TXT \"$REALM_UPPER\""
  chown root:bind "$zone_file" 2>/dev/null || true
  chmod 640 "$zone_file" 2>/dev/null || true
  if command_exists named-checkconf; then
    named-checkconf /etc/bind/named.conf || true
  fi
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

ensure_raid_fstab_entry() {
  local uuid=""
  backup_file /etc/fstab
  uuid="$(blkid -s UUID -o value /dev/md0p1 2>/dev/null || true)"
  if [ -n "$uuid" ]; then
    ensure_line /etc/fstab "UUID=$uuid /raid ext4 defaults,nofail 0 0"
  else
    ensure_line /etc/fstab "/dev/md0p1 /raid ext4 defaults,nofail 0 0"
  fi
}

setup_raid_mount() {
  install_packages mdadm parted
  mkdir -p /raid
  mkdir -p /etc/mdadm
  if [ ! -b /dev/md0p1 ]; then
    if [ ! -b /dev/md0 ]; then
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
    fi

    if [ ! -b /dev/md0p1 ]; then
      parted -s /dev/md0 mklabel gpt
      parted -s /dev/md0 mkpart primary ext4 1MiB 100%
      partprobe /dev/md0 || true
      sleep 2
    fi
  fi

  if [ -b /dev/md0p1 ] && ! blkid /dev/md0p1 >/dev/null 2>&1; then
    mkfs.ext4 -F /dev/md0p1
  fi

  if [ -b /dev/md0p1 ]; then
    mountpoint -q /raid || mount /dev/md0p1 /raid || true
    mdadm --detail --scan > /etc/mdadm/mdadm.conf
    ensure_raid_fstab_entry
    update-initramfs -u || true
  fi
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
  local web_src index_src logo_src web_password
  install_packages apache2 mariadb-server php php-mysql php-cli php-gd libapache2-mod-php curl
  service_restart_enable mariadb
  local admin_sql_password
  admin_sql_password="$(sql_literal_escape "$ADMIN_PASSWORD")"
  sql_root "CREATE DATABASE IF NOT EXISTS webdb;"
  sql_root "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
  sql_root "CREATE USER IF NOT EXISTS 'user'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost'; FLUSH PRIVILEGES;"
  prepare_additional_workspace || { log_error "Additional ISO is required for HQ web files"; return 1; }
  web_src="$ADDITIONAL_WORKDIR/web"
  index_src="$web_src/index.php"
  logo_src="$web_src/logo.png"
  [ -d "$web_src" ] || { log_error "Web directory not found in Additional workspace: $web_src"; return 1; }
  [ -s "$index_src" ] || { log_error "Required web file not found or empty: $index_src"; return 1; }
  [ -f "$web_src/dump.sql" ] && { mariadb -u root webdb < "$web_src/dump.sql" || mysql -u root webdb < "$web_src/dump.sql" || true; }
  backup_file /var/www/html/index.php
  cp "$index_src" /var/www/html/index.php
  mkdir -p /var/www/html/images
  [ -f "$logo_src" ] && cp "$logo_src" /var/www/html/images/logo.png
  if [ -s /var/www/html/index.php ]; then
    web_password="$(php_double_quoted_escape "$ADMIN_PASSWORD")"
    web_password="$(sed_replacement_escape "$web_password")"
    sed -i -E 's/\$servername *= *"[^"]*";/\$servername = "localhost";/' /var/www/html/index.php || true
    sed -i -E 's/\$username *= *"[^"]*";/\$username = "web";/' /var/www/html/index.php || true
    sed -i -E "s/\\\$password *= *\"[^\"]*\";/\\\$password = \"$web_password\";/" /var/www/html/index.php || true
    sed -i -E 's/\$dbname *= *"[^"]*";/\$dbname = "webdb";/' /var/www/html/index.php || true
  fi
  [ -f /var/www/html/index.html ] && mv /var/www/html/index.html /var/www/html/index.html.backup
  [ -f /var/www/html/index.apache2-debian.html ] && mv /var/www/html/index.apache2-debian.html /var/www/html/index.apache2-debian.html.backup
  [ -f /etc/apache2/mods-available/dir.conf ] && {
    backup_file /etc/apache2/mods-available/dir.conf
    sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/' /etc/apache2/mods-available/dir.conf
  }
  if [ -f /etc/apache2/mods-enabled/dir.conf ]; then
    backup_file /etc/apache2/mods-enabled/dir.conf
    sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/' /etc/apache2/mods-enabled/dir.conf
  fi
  if command_exists a2enmod; then
    a2enmod rewrite >/dev/null 2>&1 || true
    a2enmod php* >/dev/null 2>&1 || true
  fi
  chown -R www-data:www-data /var/www/html
  chmod -R 755 /var/www/html
  service_restart_enable apache2
  if [ ! -s /var/www/html/index.php ]; then
    log_error "HQ web application index.php was not deployed"
    return 1
  fi
  if wait_for_check 12 5 "! curl -fsS http://127.0.0.1/ | grep -q 'Apache2 Debian Default Page'"; then
    log_ok "Web app answers on HQ-SRV"
  else
    log_error "Apache still serves the default page on HQ-SRV"
    return 1
  fi
}

setup_import_users_from_csv() {
  local csv_src=""
  prepare_additional_workspace || { log_warn "Additional ISO not available, CSV import skipped"; return 0; }
  for csv_src in \
    "$ADDITIONAL_WORKDIR/$USERS_CSV_PATH" \
    "$ADDITIONAL_WORKDIR/Users.csv" \
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
  log_skip "CSV domain user import is deferred to Module 3"
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
  if ! command_exists docker; then
    curl -fsSL https://get.docker.com | sh
  fi
  service_restart_enable docker
  prepare_additional_workspace || return 1
  [ -f "$ADDITIONAL_WORKDIR/$DOCKER_DB_TAR" ] && docker load -i "$ADDITIONAL_WORKDIR/$DOCKER_DB_TAR"
  [ -f "$ADDITIONAL_WORKDIR/$DOCKER_SITE_TAR" ] && docker load -i "$ADDITIONAL_WORKDIR/$DOCKER_SITE_TAR"
  retag_docker_image_if_needed "$DOCKER_DB_IMAGE" mariadb:latest
  require_docker_image "$DOCKER_SITE_IMAGE" || return 1
  require_docker_image "$DOCKER_DB_IMAGE" || return 1
  mkdir -p "$ADDITIONAL_WORKDIR/docker"
  backup_file "$ADDITIONAL_WORKDIR/docker/docker-compose.yml"
  cat > "$ADDITIONAL_WORKDIR/docker/docker-compose.yml" <<EOF
version: '3.8'
services:
  database:
    container_name: db
    image: $DOCKER_DB_IMAGE
    restart: always
    ports:
      - "3306:3306"
    environment:
      MARIADB_DATABASE: "$DOCKER_DB_NAME"
      MARIADB_USER: "$DOCKER_DB_USER"
      MARIADB_PASSWORD: "$DOCKER_DB_PASSWORD"
      MARIADB_ROOT_PASSWORD: "$DOCKER_DB_ROOT_PASSWORD"
    volumes:
      - db_data:/var/lib/mysql

  app:
    container_name: testapp
    image: $DOCKER_SITE_IMAGE
    restart: always
    ports:
      - "8080:8000"
    environment:
      DB_TYPE: "maria"
      DB_HOST: "database"
      DB_PORT: "3306"
      DB_NAME: "$DOCKER_DB_NAME"
      DB_USER: "$DOCKER_DB_USER"
      DB_PASS: "$DOCKER_DB_PASSWORD"
      SERVER_PORT: "8080"
    depends_on:
      - database
volumes:
  db_data:
EOF
  chmod -R 755 "$ADDITIONAL_WORKDIR"
  cd "$ADDITIONAL_WORKDIR/docker"
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
  install_packages openssh-server realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common samba-common-bin packagekit krb5-user nfs-common oddjob oddjob-mkhomedir dnsutils curl
  # Keep DNS order stable: HQ-SRV first, BR-SRV second; localhost only where valid by role.
  configure_resolv_conf
  enable_service_any ssh sshd
  restart_service_any ssh sshd
  realm discover "$DOMAIN_LOWER" >/dev/null 2>&1 || true
  if ! realm list 2>/dev/null | grep -qi "$DOMAIN_LOWER"; then
    echo "$ADMIN_PASSWORD" | realm join -v --user=Administrator "$DOMAIN_LOWER" || log_warn "realm join failed"
  else
    log_skip "HQ-CLI already joined to domain"
  fi
  enable_service sssd
  restart_service sssd
  kinit Administrator >/dev/null 2>&1 || true
  klist >/dev/null 2>&1 || true
  configure_hq_domain_sudoers
  pam-auth-update --enable mkhomedir --force 2>/dev/null || true
  showmount -e "$HQ_SRV_IP" >/dev/null 2>&1 || true
  mkdir -p /mnt/nfs
  mountpoint -q /mnt/nfs || mount "$HQ_SRV_IP:$NFS_DIR" /mnt/nfs || log_warn "NFS mount failed; fstab still configured"
  backup_file /etc/fstab
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
    log_ok "Apply ISP chrony server"
    setup_chrony_server
    log_ok "Apply ISP nginx reverse proxy"
    setup_isp_proxy
    ;;
  HQ-RTR)
    log_ok "Apply HQ-RTR DNAT"
    setup_router_dnat "$HQ_SRV_IP" "$HQ_RTR_WAN_IP" "${WAN_IFACE:-ens33}"
    ;;
  BR-RTR)
    log_ok "Apply BR-RTR chrony client"
    setup_chrony_client
    log_ok "Apply BR-RTR DNAT"
    setup_router_dnat "$BR_SRV_IP" "$BR_RTR_WAN_IP" "${WAN_IFACE:-ens33}"
    ;;
  HQ-SRV)
    log_ok "Apply HQ-SRV chrony client"
    setup_chrony_client
    log_ok "Apply HQ-SRV DNS AD records"
    setup_bind_ad_records
    log_ok "Apply HQ-SRV NFS server"
    setup_nfs_server
    log_ok "Apply HQ-SRV web app"
    setup_hq_web
    ;;
  BR-SRV)
    log_ok "Apply BR-SRV chrony client"
    setup_chrony_client
    log_ok "Apply BR-SRV Samba AD DC"
    setup_samba_dc
    log_ok "Apply BR-SRV Ansible config"
    setup_ansible_br_srv
    log_ok "Apply BR-SRV Docker app"
    setup_docker_app_br_srv
    ;;
  HQ-CLI)
    log_ok "Apply HQ-CLI domain and NFS client"
    setup_hq_cli_domain_nfs
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
