#!/bin/bash
# Module 3 fixpack: ISP orchestration + package install + basic auto configuration
# Version: 0.6.11-module3-isp-fixpack

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"
PROJECT_DIR="${PROJECT_DIR:-/opt/demo-autoconfig}"

mkdir -p "$(dirname "$LOG_FILE")" /etc/demo-autoconfig 2>/dev/null || true
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s 2>/dev/null | tr '[:lower:]' '[:upper:]')}"
DOMAIN="${DOMAIN:-au-team.irpo}"

HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"

SSH_SERVER_USER="${SSH_SERVER_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_SERVER_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}"
SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"

SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"

SSH_CLI_USER="${SSH_CLI_USER:-sshuser}"
SSH_CLI_PASSWORD="${SSH_CLI_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}"
SSH_CLI_PORT="${SSH_CLI_PORT:-22}"

MODULE3_ORCHESTRATE_FROM_ISP="${MODULE3_ORCHESTRATE_FROM_ISP:-yes}"
MODULE3_INSTALL_ONLY="${MODULE3_INSTALL_ONLY:-no}"
MODULE3_IPSEC_PSK="${MODULE3_IPSEC_PSK:-1c+rYtGm}"
MODULE3_USERS_CSV="${MODULE3_USERS_CSV:-/mnt/additional/Users.csv}"

WEB_AUTH_USER="${WEB_AUTH_USER:-WEB}"
WEB_AUTH_PASS="${WEB_AUTH_PASS:-P@ssw0rd}"

DOCKER_SITE_IMAGE="${DOCKER_SITE_IMAGE:-site_latest:latest}"
DOCKER_DB_IMAGE="${DOCKER_DB_IMAGE:-mariadb_latest:latest}"

ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }
warn() { echo "$(date '+%F %T') [WARN] $*" | tee -a "$LOG_FILE"; }
fail() { echo "$(date '+%F %T') [FAIL] $*" | tee -a "$LOG_FILE"; }
info() { echo "$(date '+%F %T') [INFO] $*" | tee -a "$LOG_FILE"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_project_in_opt() {
  mkdir -p "$PROJECT_DIR"
  local current_dir
  current_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  if [ -f "$current_dir/menu.sh" ]; then
    cp -a "$current_dir"/. "$PROJECT_DIR"/
    chmod +x "$PROJECT_DIR"/menu.sh "$PROJECT_DIR"/modules/*.sh 2>/dev/null || true
    ok "Project copied to $PROJECT_DIR"
  elif [ -f "$PROJECT_DIR/menu.sh" ]; then
    ok "Project already exists in $PROJECT_DIR"
  else
    warn "Cannot find project source to copy into $PROJECT_DIR"
  fi
}

fix_common_defaults_in_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  grep -q '^SSH_ROUTER_PORT=2026' "$CONFIG_FILE" && sed -i 's/^SSH_ROUTER_PORT=.*/SSH_ROUTER_PORT=22/' "$CONFIG_FILE" && ok "Fixed SSH_ROUTER_PORT=22"
  grep -q '^DOCKER_SITE_IMAGE=site:latest' "$CONFIG_FILE" && sed -i 's/^DOCKER_SITE_IMAGE=.*/DOCKER_SITE_IMAGE=site_latest:latest/' "$CONFIG_FILE" && ok "Fixed DOCKER_SITE_IMAGE"
  grep -q '^DOCKER_DB_IMAGE=mariadb:10.11' "$CONFIG_FILE" && sed -i 's/^DOCKER_DB_IMAGE=.*/DOCKER_DB_IMAGE=mariadb_latest:latest/' "$CONFIG_FILE" && ok "Fixed DOCKER_DB_IMAGE"
}

write_resolv_conf_role() {
  case "$ROLE" in
    HQ-SRV|hq-srv)
      cat > /etc/resolv.conf <<EOF
search $DOMAIN
options timeout:2 attempts:3
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF
      ;;
    BR-SRV|br-srv)
      if systemctl is-active --quiet samba-ad-dc; then
        cat > /etc/resolv.conf <<EOF
search $DOMAIN
options timeout:2 attempts:3
nameserver 127.0.0.1
nameserver $HQ_SRV_IP
nameserver 8.8.8.8
EOF
      else
        cat > /etc/resolv.conf <<EOF
search $DOMAIN
options timeout:2 attempts:3
nameserver $HQ_SRV_IP
nameserver 8.8.8.8
EOF
      fi
      ;;
    *)
      cat > /etc/resolv.conf <<EOF
search $DOMAIN
options timeout:2 attempts:3
nameserver $HQ_SRV_IP
nameserver $BR_SRV_IP
nameserver 8.8.8.8
EOF
      ;;
  esac
  ok "resolv.conf updated for $ROLE"
}

ssh_run() {
  local host="$1" port="$2" user="$3"
  shift 3
  local command="$*"
  if cmd_exists sshpass; then
    local pass="$SSH_SERVER_PASSWORD"
    [ "$user" = "$SSH_ROUTER_USER" ] && pass="$SSH_ROUTER_PASSWORD"
    [ "$user" = "$SSH_CLI_USER" ] && pass="$SSH_CLI_PASSWORD"
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$port" "$user@$host" "$command"
  else
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$port" "$user@$host" "$command"
  fi
}

ssh_copy_project() {
  local host="$1" port="$2" user="$3"
  local tarball="/tmp/demo-autoconfig-push.tar.gz"
  tar -C "$PROJECT_DIR" -czf "$tarball" . 2>/dev/null || { warn "Cannot create project tarball"; return 1; }

  if cmd_exists sshpass; then
    local pass="$SSH_SERVER_PASSWORD"
    [ "$user" = "$SSH_ROUTER_USER" ] && pass="$SSH_ROUTER_PASSWORD"
    [ "$user" = "$SSH_CLI_USER" ] && pass="$SSH_CLI_PASSWORD"
    sshpass -p "$pass" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$port" "$tarball" "$user@$host:/tmp/demo-autoconfig-push.tar.gz" || return 1
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P "$port" "$tarball" "$user@$host:/tmp/demo-autoconfig-push.tar.gz" || return 1
  fi

  ssh_run "$host" "$port" "$user" "sudo mkdir -p /opt/demo-autoconfig && sudo tar -xzf /tmp/demo-autoconfig-push.tar.gz -C /opt/demo-autoconfig && sudo chmod +x /opt/demo-autoconfig/menu.sh /opt/demo-autoconfig/modules/*.sh 2>/dev/null || true"
}

install_common_packages() {
  apt_install curl wget ca-certificates dnsutils netcat-openbsd openssh-client openssh-server sudo
}

install_role_packages() {
  case "$ROLE" in
    ISP|isp) apt_install sshpass nginx apache2-utils curl wget dnsutils openssl ca-certificates ;;
    HQ-RTR|hq-rtr|BR-RTR|br-rtr) apt_install strongswan iptables iptables-persistent netfilter-persistent curl wget dnsutils openssh-server sudo ;;
    HQ-SRV|hq-srv) apt_install cups printer-driver-cups-pdf rsyslog logrotate fail2ban curl wget dnsutils openssl ca-certificates nginx apache2-utils ;;
    BR-SRV|br-srv) apt_install samba winbind smbclient krb5-user rsyslog logrotate curl wget dnsutils ;;
    HQ-CLI|hq-cli) apt_install cups-client system-config-printer curl wget dnsutils ca-certificates openssl ;;
    *) warn "Unknown role for package install: $ROLE" ;;
  esac
}

configure_ipsec_router() {
  case "$ROLE" in
    HQ-RTR|hq-rtr) local local_ip="$HQ_RTR_WAN_IP"; local remote_ip="$BR_RTR_WAN_IP" ;;
    BR-RTR|br-rtr) local local_ip="$BR_RTR_WAN_IP"; local remote_ip="$HQ_RTR_WAN_IP" ;;
    *) return 0 ;;
  esac

  cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 1"

conn gre-protect
    auto=start
    keyexchange=ikev2
    type=transport
    authby=psk
    left=$local_ip
    right=$remote_ip
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    dpdaction=restart
    dpddelay=10s
    dpdtimeout=30s
EOF

  cat > /etc/ipsec.secrets <<EOF
$local_ip $remote_ip : PSK "$MODULE3_IPSEC_PSK"
EOF
  chmod 600 /etc/ipsec.secrets

  systemctl enable --now strongswan-starter >/dev/null 2>&1 || systemctl enable --now strongswan >/dev/null 2>&1
  systemctl restart strongswan-starter >/dev/null 2>&1 || systemctl restart strongswan >/dev/null 2>&1
  ok "IPsec transport config applied on $ROLE"
}

configure_router_firewall() {
  local ipt="/usr/sbin/iptables"
  [ -x "$ipt" ] || ipt="$(command -v iptables)"
  [ -n "$ipt" ] || { fail "iptables not found"; return 1; }
  "$ipt" -P INPUT ACCEPT
  "$ipt" -P OUTPUT ACCEPT
  "$ipt" -P FORWARD ACCEPT
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules 2>/dev/null || true
  ok "basic firewall permissive rules saved on $ROLE"
}

import_users_br_srv() {
  [ -f "$MODULE3_USERS_CSV" ] || { fail "Users CSV not found: $MODULE3_USERS_CSV"; return 1; }
  cmd_exists samba-tool || { fail "samba-tool not found"; return 1; }

  local base_dn="DC=au-team,DC=irpo"

  awk -F ';' 'NR>1 {gsub("\r","",$5); if($5!="") print $5}' "$MODULE3_USERS_CSV" | sort -u | while IFS= read -r ou; do
    ou="${ou#OU=}"; ou="${ou%%,DC=*}"; ou="$(echo "$ou" | xargs)"
    [ -z "$ou" ] && continue
    samba-tool ou list | tr -d '\r' | grep -Fxq "OU=$ou" && ok "OU exists: $ou" || samba-tool ou add "OU=$ou,$base_dn"
  done

  tail -n +2 "$MODULE3_USERS_CSV" | while IFS=';' read -r firstName lastName role phone ou street zip city country password; do
    firstName="${firstName//$'\r'/}"; lastName="${lastName//$'\r'/}"; role="${role//$'\r'/}"; phone="${phone//$'\r'/}"; ou="${ou//$'\r'/}"; password="${password//$'\r'/}"
    [ -z "$firstName" ] && continue
    [ -z "$lastName" ] && continue
    [ -z "$password" ] && password="P@ssw0rd"
    ou="${ou#OU=}"; ou="${ou%%,DC=*}"; ou="$(echo "$ou" | xargs)"
    username="$(echo "${firstName,,}.${lastName,,}" | tr -d ' ')"

    if samba-tool user show "$username" >/dev/null 2>&1; then
      ok "user exists: $username"
      continue
    fi

    samba-tool user add "$username" "$password" --given-name="$firstName" --surname="$lastName" --telephone-number="$phone" --job-title="$role" --userou="OU=$ou" >/dev/null 2>&1
    [ $? -eq 0 ] && { samba-tool user setexpiry "$username" --noexpiry >/dev/null 2>&1; ok "user added: $username"; } || fail "user add failed: $username"
  done

  ok "Samba users count: $(samba-tool user list | wc -l)"
}

configure_hq_srv_services() {
  systemctl enable --now cups >/dev/null 2>&1 && ok "CUPS enabled" || warn "CUPS enable failed"
  if ! lpstat -p 2>/dev/null | grep -q CUPS-PDF; then
    lpadmin -p CUPS-PDF -E -v cups-pdf:/ -m drv:///sample.drv/generic.ppd >/dev/null 2>&1 && ok "CUPS-PDF added" || warn "CUPS-PDF add failed"
  fi
  mkdir -p /opt
  systemctl enable --now rsyslog >/dev/null 2>&1 && ok "rsyslog enabled" || warn "rsyslog enable failed"
  cat > /etc/logrotate.d/opt-rsyslog <<'EOF'
/opt/*/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    minsize 10M
}
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban enabled" || warn "fail2ban enable failed"
}

configure_isp_https_nginx() {
  mkdir -p /etc/nginx/ssl
  if [ ! -f /etc/nginx/ssl/demo.key ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 -keyout /etc/nginx/ssl/demo.key -out /etc/nginx/ssl/demo.crt -subj "/CN=au-team.irpo" >/dev/null 2>&1
  fi
  cmd_exists htpasswd && htpasswd -bc /etc/nginx/.htpasswd "$WEB_AUTH_USER" "$WEB_AUTH_PASS" >/dev/null 2>&1

  cat > /etc/nginx/sites-available/demo-autoconfig-proxy <<EOF
server {
    listen 80;
    server_name web.$DOMAIN;
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / { proxy_pass http://$HQ_SRV_IP:80; }
}
server {
    listen 80;
    server_name docker.$DOMAIN;
    location / { proxy_pass http://$BR_SRV_IP:8080; }
}
server {
    listen 443 ssl;
    server_name web.$DOMAIN;
    ssl_certificate /etc/nginx/ssl/demo.crt;
    ssl_certificate_key /etc/nginx/ssl/demo.key;
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / { proxy_pass http://$HQ_SRV_IP:80; }
}
server {
    listen 443 ssl;
    server_name docker.$DOMAIN;
    ssl_certificate /etc/nginx/ssl/demo.crt;
    ssl_certificate_key /etc/nginx/ssl/demo.key;
    location / { proxy_pass http://$BR_SRV_IP:8080; }
}
EOF

  ln -sf /etc/nginx/sites-available/demo-autoconfig-proxy /etc/nginx/sites-enabled/demo-autoconfig-proxy
  nginx -t >/dev/null 2>&1 && systemctl reload nginx && ok "nginx HTTP/HTTPS proxy configured" || fail "nginx config failed"
}

configure_hq_cli() {
  systemctl enable --now cups >/dev/null 2>&1 || true
  mkdir -p /backup
  ok "HQ-CLI basic module3 client config done"
}

local_module3() {
  info "Module 3 local role: $ROLE"
  ensure_project_in_opt
  fix_common_defaults_in_config
  write_resolv_conf_role
  install_common_packages
  install_role_packages

  if [ "$MODULE3_INSTALL_ONLY" = "yes" ]; then
    ok "MODULE3_INSTALL_ONLY=yes, only packages installed"
    return 0
  fi

  case "$ROLE" in
    ISP|isp) configure_isp_https_nginx ;;
    HQ-RTR|hq-rtr|BR-RTR|br-rtr) configure_ipsec_router; configure_router_firewall ;;
    BR-SRV|br-srv) import_users_br_srv; systemctl enable --now rsyslog >/dev/null 2>&1 || true ;;
    HQ-SRV|hq-srv) configure_hq_srv_services ;;
    HQ-CLI|hq-cli) configure_hq_cli ;;
    *) warn "No module3 actions for role: $ROLE" ;;
  esac

  ok "Module 3 local finished for $ROLE"
}

remote_run_module3() {
  local title="$1" host="$2" port="$3" user="$4"
  info "Remote Module3 start: $title $user@$host:$port"
  ssh_copy_project "$host" "$port" "$user" || { fail "Project copy failed: $title"; return 1; }
  ssh_run "$host" "$port" "$user" "sudo bash /opt/demo-autoconfig/modules/module3.sh --local" && ok "Remote Module3 finished: $title" || fail "Remote Module3 failed: $title"
}

orchestrate_from_isp() {
  ROLE="ISP"
  ensure_project_in_opt
  fix_common_defaults_in_config
  install_common_packages
  apt_install sshpass

  remote_run_module3 "HQ-RTR" "$HQ_RTR_WAN_IP" "$SSH_ROUTER_PORT" "$SSH_ROUTER_USER"
  remote_run_module3 "BR-RTR" "$BR_RTR_WAN_IP" "$SSH_ROUTER_PORT" "$SSH_ROUTER_USER"
  remote_run_module3 "HQ-SRV" "$HQ_SRV_IP" "$SSH_SERVER_PORT" "$SSH_SERVER_USER"
  remote_run_module3 "BR-SRV" "$BR_SRV_IP" "$SSH_SERVER_PORT" "$SSH_SERVER_USER"
  remote_run_module3 "HQ-CLI" "$HQ_CLI_IP" "$SSH_CLI_PORT" "$SSH_CLI_USER"

  local_module3
  ok "Module 3 ISP orchestration completed"
}

if [ "${1:-}" = "--local" ]; then
  local_module3
elif [[ "$ROLE" =~ ^(ISP|isp)$ ]] && [ "$MODULE3_ORCHESTRATE_FROM_ISP" = "yes" ]; then
  orchestrate_from_isp
else
  local_module3
fi
