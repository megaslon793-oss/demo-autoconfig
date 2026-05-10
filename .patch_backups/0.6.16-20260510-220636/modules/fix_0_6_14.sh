#!/bin/bash
# fix_0_6_14.sh
# Fixes:
# 1) Router SSH for net_admin must use port 22
# 2) Preferred interfaces order: ens33, ens37, ens38, ...
# 3) Remove sshuser on HQ-CLI
# 4) Disable bind9 automatically on BR-SRV

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

mkdir -p /etc/demo-autoconfig "$(dirname "$LOG_FILE")" 2>/dev/null || true

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"
DOMAIN="${DOMAIN:-au-team.irpo}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"

log_ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "$(date '+%F %T') [WARN] $*" | tee -a "$LOG_FILE"; }
log_fail() { echo "$(date '+%F %T') [FAIL] $*" | tee -a "$LOG_FILE"; }

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p /etc/demo-autoconfig/backups
  cp -a "$f" "/etc/demo-autoconfig/backups/$(echo "$f" | sed 's#/#_#g').$(date +%Y%m%d-%H%M%S).bak"
}

set_config_kv() {
  local key="$1"
  local value="$2"
  [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

  backup_file "$CONFIG_FILE"

  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
}

normalize_router_ssh_port() {
  set_config_kv "SSH_ROUTER_PORT" "22"
  set_config_kv "SSH_ROUTER_USER" "net_admin"

  case "$ROLE" in
    HQ-RTR|hq-rtr|BR-RTR|br-rtr|hqr|brr)
      if [ -f /etc/ssh/sshd_config ]; then
        backup_file /etc/ssh/sshd_config

        if grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
          sed -i 's/^[#[:space:]]*Port[[:space:]].*/Port 22/' /etc/ssh/sshd_config
        else
          echo 'Port 22' >> /etc/ssh/sshd_config
        fi

        if grep -qE '^[#[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config; then
          sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        else
          echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
        fi

        if grep -qE '^[#[:space:]]*AllowUsers' /etc/ssh/sshd_config; then
          if ! grep -E '^[#[:space:]]*AllowUsers' /etc/ssh/sshd_config | grep -q 'net_admin'; then
            sed -i 's/^[#[:space:]]*AllowUsers.*/AllowUsers net_admin/' /etc/ssh/sshd_config
          fi
        else
          echo 'AllowUsers net_admin' >> /etc/ssh/sshd_config
        fi

        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        log_ok "Router SSH fixed: net_admin on port 22"
      else
        log_warn "sshd_config not found, only config.env fixed"
      fi
      ;;
    *)
      log_ok "Config fixed: SSH_ROUTER_PORT=22"
      ;;
  esac
}

normalize_interface_order_config() {
  set_config_kv "PREFERRED_IFACE_ORDER" "ens33\\ ens37\\ ens38\\ ens39\\ ens40"
  set_config_kv "INTERFACES" "ens33\\ ens37\\ ens38"

  case "$ROLE" in
    ISP|isp)
      set_config_kv "WAN_IFACE" "ens33"
      set_config_kv "IPV4_CONFIGS" "ens33:dhcp\\ ens37:172.16.1.1/28\\ ens38:172.16.2.1/28"
      set_config_kv "NAT_OUT_IFACE" "ens33"
      set_config_kv "STATIC_ROUTES" "192.168.100.0/28:172.16.1.2:ens37\\ 192.168.200.0/27:172.16.1.2:ens37\\ 192.168.250.0/29:172.16.1.2:ens37\\ 192.168.255.0/28:172.16.2.2:ens38"
      log_ok "ISP config interface order fixed: ens33, ens37, ens38"
      ;;
    HQ-RTR|hq-rtr|hqr)
      set_config_kv "INTERFACES" "ens33\\ ens37"
      set_config_kv "WAN_IFACE" "ens33"
      set_config_kv "LAN_IFACE" "ens37"
      log_ok "HQ-RTR config interface order fixed: ens33 WAN, ens37 LAN/trunk"
      ;;
    BR-RTR|br-rtr|brr)
      set_config_kv "INTERFACES" "ens33\\ ens37"
      set_config_kv "WAN_IFACE" "ens33"
      set_config_kv "LAN_IFACE" "ens37"
      log_ok "BR-RTR config interface order fixed: ens33 WAN, ens37 LAN"
      ;;
    *)
      log_ok "Preferred interface order saved to config"
      ;;
  esac
}

remove_sshuser_on_hq_cli() {
  case "$ROLE" in
    HQ-CLI|hq-cli)
      if id sshuser >/dev/null 2>&1; then
        if [ "$(id -un 2>/dev/null)" = "sshuser" ]; then
          log_warn "Current session is sshuser, not deleting active user"
          return 0
        fi

        pkill -u sshuser 2>/dev/null || true
        userdel -r sshuser 2>/dev/null

        if id sshuser >/dev/null 2>&1; then
          log_fail "Failed to delete sshuser on HQ-CLI"
          return 1
        else
          log_ok "sshuser removed from HQ-CLI"
        fi
      else
        log_ok "sshuser already absent on HQ-CLI"
      fi
      ;;
    *)
      log_ok "sshuser removal skipped: ROLE=$ROLE"
      ;;
  esac
}

disable_bind9_on_br_srv() {
  case "$ROLE" in
    BR-SRV|br-srv)
      systemctl disable --now bind9 2>/dev/null || true
      systemctl disable --now named 2>/dev/null || true

      if systemctl is-active --quiet bind9 2>/dev/null || systemctl is-active --quiet named 2>/dev/null; then
        log_fail "bind9/named is still active on BR-SRV"
      else
        log_ok "bind9/named disabled on BR-SRV"
      fi

      if systemctl is-active --quiet samba-ad-dc; then
        backup_file /etc/resolv.conf
        cat > /etc/resolv.conf <<EOF
search $DOMAIN
options timeout:2 attempts:3
nameserver 127.0.0.1
nameserver $HQ_SRV_IP
nameserver 8.8.8.8
EOF
        log_ok "BR-SRV resolv.conf fixed for Samba DNS"
      fi
      ;;
    *)
      log_ok "bind9 disable skipped: ROLE=$ROLE"
      ;;
  esac
}

print_summary() {
  echo
  echo "===== FIX 0.6.14 SUMMARY ====="
  echo "ROLE=$ROLE"
  echo "CONFIG_FILE=$CONFIG_FILE"
  echo "SSH_ROUTER_PORT=$(grep '^SSH_ROUTER_PORT=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  echo "PREFERRED_IFACE_ORDER=$(grep '^PREFERRED_IFACE_ORDER=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-)"
  echo
}

main() {
  log_ok "Starting fix 0.6.14"

  normalize_router_ssh_port
  normalize_interface_order_config
  remove_sshuser_on_hq_cli
  disable_bind9_on_br_srv

  print_summary
  log_ok "Fix 0.6.14 finished"
}

main "$@"
