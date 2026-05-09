#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

ROLE="${M3_FORCE_ROLE:-${ROLE:-}}"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-P@ssw0rd}"
DOMAIN_LOWER="${DOMAIN:-au-team.irpo}"
REALM_UPPER="${REALM_UPPER:-$(printf '%s' "$DOMAIN_LOWER" | tr '[:lower:]' '[:upper:]')}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-192.168.100.1}"
HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
SSH_SERVER_USER="${SSH_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_PASSWORD:-$ADMIN_PASSWORD}"
SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"
HQ_CLI_ANSIBLE_USER="${HQ_CLI_ANSIBLE_USER:-user}"
HQ_CLI_ANSIBLE_PASSWORD="${HQ_CLI_ANSIBLE_PASSWORD:-root}"
HQ_CLI_ANSIBLE_PORT="${HQ_CLI_ANSIBLE_PORT:-22}"
ISO_DIR="${ISO_MOUNTPOINT:-/mnt/additional}"
MODULE3_ORCHESTRATE_FROM_ISP="${MODULE3_ORCHESTRATE_FROM_ISP:-yes}"
MODULE3_INSTALL_ONLY="${MODULE3_INSTALL_ONLY:-no}"
IPSEC_PSK="${IPSEC_PSK:-$ADMIN_PASSWORD}"

ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

service_restart_enable() {
  enable_service_any "$1" || true
  restart_service_any "$1" || true
}

prepare_iso_mount() {
  local candidate
  for candidate in "$ISO_DIR" /mnt/additional /media/cdrom /media/cdrom0 /tmp/additional; do
    [ -d "$candidate" ] || continue
    if [ -f "$candidate/Users.csv" ] || [ -f "$candidate/users.csv" ] || [ -d "$candidate/docker" ] || [ -d "$candidate/web" ]; then
      ISO_DIR="$candidate"
      return 0
    fi
  done
  if [ -n "${ISO_PATH:-}" ] && [ -f "$ISO_PATH" ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o loop,ro "$ISO_PATH" "$ISO_DIR" || true
    [ -f "$ISO_DIR/Users.csv" ] || [ -f "$ISO_DIR/users.csv" ] || [ -d "$ISO_DIR/docker" ] && return 0
  fi
  if [ -b /dev/sr0 ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o ro /dev/sr0 "$ISO_DIR" || true
    [ -f "$ISO_DIR/Users.csv" ] || [ -f "$ISO_DIR/users.csv" ] || [ -d "$ISO_DIR/docker" ] && return 0
  fi
  return 1
}

module3_packages_for_role() {
  case "$1" in
    ISP)
      echo "sshpass tar gzip curl wget rsync nginx apache2-utils openssl ca-certificates"
      ;;
    HQ-RTR|BR-RTR)
      echo "strongswan strongswan-starter iptables iptables-persistent netfilter-persistent rsyslog curl wget"
      ;;
    HQ-SRV)
      echo "rsyslog logrotate cups cups-pdf printer-driver-cups-pdf cups-client fail2ban borgbackup openssh-client openssl ca-certificates mariadb-client curl wget nginx apache2-utils"
      ;;
    BR-SRV)
      echo "samba samba-common-bin smbclient winbind krb5-user realmd sssd sssd-tools adcli rsyslog ansible sshpass curl wget"
      ;;
    HQ-CLI)
      echo "cups-client borgbackup openssh-server realmd sssd sssd-tools adcli samba-common-bin libnss-sss libpam-sss curl wget"
      ;;
    *) echo "curl wget" ;;
  esac
}

install_module3_packages_local() {
  local pkgs
  pkgs="$(module3_packages_for_role "$ROLE")"
  log_ok "Installing Module 3 package set for $ROLE: $pkgs"
  # shellcheck disable=SC2086
  install_packages $pkgs || log_warn "Some Module 3 packages were not installed for $ROLE. Check apt/internet/repositories."
}

remote_ssh() {
  local host="$1" port="$2" user="$3" password="$4"; shift 4
  SSHPASS="$password" sshpass -e ssh \
    -p "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    "$user@$host" "$@"
}

remote_scp() {
  local src="$1" host="$2" port="$3" user="$4" password="$5" dst="$6"
  SSHPASS="$password" sshpass -e scp \
    -P "$port" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    "$src" "$user@$host:$dst"
}

make_release_archive() {
  local out="$1"
  ( cd "$PROJECT_DIR" && tar \
      --exclude='.git' \
      --exclude='*.zip' \
      --exclude='.docx_media' \
      --exclude='_reference_scripts' \
      -czf "$out" . )
}

remote_prepare_project_and_config() {
  local role="$1" host="$2" port="$3" user="$4" password="$5"
  local archive="/tmp/demo-autoconfig-module3.tar.gz"
  local cfg="/tmp/demo-autoconfig-config.env"

  make_release_archive "$archive"
  cp "$CONFIG_FILE" "$cfg"

  log_ok "[$role] Uploading current project and config to $host"
  remote_ssh "$host" "$port" "$user" "$password" "sudo mkdir -p /opt/demo-autoconfig /etc/demo-autoconfig/backups /tmp/demo-autoconfig"
  remote_scp "$archive" "$host" "$port" "$user" "$password" "/tmp/demo-autoconfig-module3.tar.gz"
  remote_scp "$cfg" "$host" "$port" "$user" "$password" "/tmp/demo-autoconfig-config.env"
  remote_ssh "$host" "$port" "$user" "$password" "sudo sh -c 'if [ -f /etc/demo-autoconfig/config.env ]; then cp /etc/demo-autoconfig/config.env /etc/demo-autoconfig/backups/config.env.module3.\$(date +%Y%m%d-%H%M%S).bak; fi; cp /tmp/demo-autoconfig-config.env /etc/demo-autoconfig/config.env; tar -xzf /tmp/demo-autoconfig-module3.tar.gz -C /opt/demo-autoconfig; chmod +x /opt/demo-autoconfig/menu.sh /opt/demo-autoconfig/modules/*.sh 2>/dev/null || true'"
}

remote_install_packages_for_role() {
  local role="$1" host="$2" port="$3" user="$4" password="$5"
  local pkgs
  pkgs="$(module3_packages_for_role "$role")"
  log_ok "[$role] Installing packages on $host: $pkgs"
  remote_ssh "$host" "$port" "$user" "$password" "sudo env DEBIAN_FRONTEND=noninteractive bash -lc 'systemctl stop packagekit 2>/dev/null || true; apt-get -o DPkg::Lock::Timeout=180 update; apt-get -o DPkg::Lock::Timeout=180 install -y $pkgs'" || \
    log_warn "[$role] Package installation failed on $host. Continue to next host."
}

remote_run_module3_for_role() {
  local role="$1" host="$2" port="$3" user="$4" password="$5"
  log_ok "[$role] Running Module 3 on $host"
  remote_ssh "$host" "$port" "$user" "$password" "sudo env M3_FORCE_ROLE='$role' MODULE3_ORCHESTRATED='1' MODULE3_ORCHESTRATE_FROM_ISP='no' bash /opt/demo-autoconfig/modules/module3.sh" || \
    log_warn "[$role] Module 3 run failed on $host. Check remote /var/log/demo-autoconfig.log"
}

orchestrate_module3_from_isp() {
  install_packages sshpass tar gzip rsync curl wget

  local targets=(
    "$HQ_SRV_IP:$SSH_SERVER_PORT:$SSH_SERVER_USER:$SSH_SERVER_PASSWORD:HQ-SRV"
    "$HQ_CLI_IP:$HQ_CLI_ANSIBLE_PORT:$HQ_CLI_ANSIBLE_USER:$HQ_CLI_ANSIBLE_PASSWORD:HQ-CLI"
    "$BR_SRV_IP:$SSH_SERVER_PORT:$SSH_SERVER_USER:$SSH_SERVER_PASSWORD:BR-SRV"
    "$HQ_RTR_HQ_IP:$SSH_ROUTER_PORT:$SSH_ROUTER_USER:$SSH_ROUTER_PASSWORD:HQ-RTR"
    "$BR_RTR_LAN_IP:$SSH_ROUTER_PORT:$SSH_ROUTER_USER:$SSH_ROUTER_PASSWORD:BR-RTR"
  )

  local item host port user password role
  for item in "${targets[@]}"; do
    IFS=':' read -r host port user password role <<< "$item"
    log_ok "===== MODULE3 REMOTE PREPARE: $role ($host:$port as $user) ====="
    if remote_ssh "$host" "$port" "$user" "$password" "true" >/dev/null 2>&1; then
      remote_install_packages_for_role "$role" "$host" "$port" "$user" "$password"
      remote_prepare_project_and_config "$role" "$host" "$port" "$user" "$password"
      if [ "$MODULE3_INSTALL_ONLY" != "yes" ]; then
        remote_run_module3_for_role "$role" "$host" "$port" "$user" "$password"
      else
        log_skip "[$role] MODULE3_INSTALL_ONLY=yes, configuration skipped"
      fi
    else
      log_warn "[$role] SSH unavailable: $user@$host:$port. Packages/config were not applied."
    fi
  done

  log_ok "===== MODULE3 LOCAL ISP PART ====="
  install_module3_packages_local
  setup_isp_https_proxy || true
}

setup_import_users_br_srv() {
  install_packages samba-common-bin samba smbclient winbind
  prepare_iso_mount || { log_warn "Users.csv was not found in Additional ISO"; return 0; }
  local csv="$ISO_DIR/Users.csv"
  [ -f "$csv" ] || csv="$ISO_DIR/users.csv"
  [ -f "$csv" ] || { log_warn "Users.csv/users.csv was not found in $ISO_DIR"; return 0; }

  cat > /opt/import_users.sh <<'IMPORT_USERS_EOF'
#!/usr/bin/env bash
set -u
CSV_FILE="${1:-/mnt/additional/Users.csv}"
BASE_DN="${BASE_DN:-DC=au-team,DC=irpo}"
[ -f "$CSV_FILE" ] || { echo "CSV not found: $CSV_FILE"; exit 1; }

awk -F';' 'NR>1 {gsub("\r", "", $5); if ($5 != "") print $5}' "$CSV_FILE" | sort -u | while IFS= read -r ou; do
  ou="${ou#OU=}"
  ou="${ou%%,DC=*}"
  ou="$(printf '%s' "$ou" | xargs)"
  [ -z "$ou" ] && continue
  samba-tool ou add "OU=$ou,$BASE_DN" >/dev/null 2>&1 || true
  echo "[OK] OU ensured: $ou"
done

tail -n +2 "$CSV_FILE" | while IFS=';' read -r firstName lastName role phone ou street zip city country password rest; do
  firstName="${firstName//$'\r'/}"; lastName="${lastName//$'\r'/}"; role="${role//$'\r'/}"
  phone="${phone//$'\r'/}"; ou="${ou//$'\r'/}"; password="${password//$'\r'/}"
  ou="${ou#OU=}"
  ou="${ou%%,DC=*}"
  ou="$(printf '%s' "$ou" | xargs)"
  username="$(printf '%s.%s' "$firstName" "$lastName" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  [ -n "$username" ] || continue
  [ -n "$password" ] || password='P@ssw0rd'

  if samba-tool user show "$username" >/dev/null 2>&1; then
    echo "[SKIP] user exists: $username"
    continue
  fi

  echo "[ADD] user: $username OU=$ou"
  samba-tool user create "$username" "$password" \
    --given-name="$firstName" \
    --surname="$lastName" \
    --telephone-number="$phone" \
    --job-title="$role" \
    --userou="OU=$ou" || echo "[WARN] failed to create $username"

  samba-tool user setexpiry "$username" --noexpiry >/dev/null 2>&1 || true
done
IMPORT_USERS_EOF
  chmod +x /opt/import_users.sh
  BASE_DN="DC=$(printf '%s' "$DOMAIN_LOWER" | cut -d. -f1),DC=$(printf '%s' "$DOMAIN_LOWER" | cut -d. -f2)" /opt/import_users.sh "$csv"
  log_ok "User count after import: $(samba-tool user list | wc -l)"
}

setup_hq_cli_pam() {
  install_packages libpam-modules libpam-sss libnss-sss
  grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session || \
    printf 'session required pam_mkhomedir.so skel=/etc/skel/ umask=0077\n' >> /etc/pam.d/common-session
}

setup_ipsec() {
  local left_ip="$1" left_id="$2" right_ip="$3" right_id="$4"
  install_packages strongswan strongswan-starter
  backup_file /etc/ipsec.conf
  cat > /etc/ipsec.conf <<IPSEC_CONF_EOF
config setup
    charondebug="ike 1, knl 1, cfg 1"
    uniqueids=no

conn %default
    keyexchange=ikev2
    ike=aes256-sha2_256-modp2048!
    esp=aes256-sha2_256!
    leftauth=psk
    rightauth=psk
    auto=start
    dpdaction=restart
    closeaction=restart

conn gre-encrypt
    left=$left_ip
    leftid=@$left_id
    right=$right_ip
    rightid=@$right_id
    type=transport
    authby=psk
    leftprotoport=47
    rightprotoport=47
IPSEC_CONF_EOF
  backup_file /etc/ipsec.secrets
  cat > /etc/ipsec.secrets <<IPSEC_SECRETS_EOF
@$left_id @$right_id : PSK "$IPSEC_PSK"
IPSEC_SECRETS_EOF
  chmod 600 /etc/ipsec.secrets
  systemctl enable --now strongswan-starter 2>/dev/null || systemctl enable --now ipsec 2>/dev/null || true
  systemctl restart strongswan-starter 2>/dev/null || systemctl restart ipsec 2>/dev/null || true
  command -v ipsec >/dev/null 2>&1 && ipsec rereadsecrets || true
  command -v ipsec >/dev/null 2>&1 && ipsec restart || true
}

setup_firewall_router() {
  local dest="$1" wan_if="${NAT_OUT_IFACE:-${WAN_IFACE:-ens33}}"
  ensure_iptables_available
  backup_file /etc/start_iptables.sh
  cat > /etc/start_iptables.sh <<FW_EOF
#!/usr/bin/env bash
set -e
IPT="\$(command -v iptables 2>/dev/null || printf '/usr/sbin/iptables')"
WAN_IF="$wan_if"
DEST="$dest"
"\$IPT" -P INPUT ACCEPT
"\$IPT" -P FORWARD ACCEPT
"\$IPT" -P OUTPUT ACCEPT
"\$IPT" -F
"\$IPT" -t nat -F
"\$IPT" -t mangle -F
"\$IPT" -t raw -F
"\$IPT" -A INPUT -i lo -j ACCEPT
"\$IPT" -A OUTPUT -o lo -j ACCEPT
"\$IPT" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for proto in icmp ospf gre; do "\$IPT" -A INPUT -p "\$proto" -j ACCEPT; "\$IPT" -A OUTPUT -p "\$proto" -j ACCEPT; "\$IPT" -A FORWARD -p "\$proto" -j ACCEPT; done
"\$IPT" -A INPUT -p 50 -j ACCEPT
"\$IPT" -A OUTPUT -p 50 -j ACCEPT
"\$IPT" -A FORWARD -p 50 -j ACCEPT
"\$IPT" -A INPUT -p udp -m multiport --dports 500,4500,53,123,514 -j ACCEPT
"\$IPT" -A OUTPUT -p udp -m multiport --dports 500,4500,53,123,514 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 500,4500,53,123,514 -j ACCEPT
"\$IPT" -A INPUT -p tcp -m multiport --dports 22,2026,53,80,443,8080,514,631,10050,10051 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp -m multiport --dports 22,2026,53,80,443,8080,514,631,10050,10051 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 22,2026,53,80,443,8080,514,631,10050,10051 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 88,135,139,389,445,464,636,3268,3269,111,2049,20048 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 88,137,138,389,464,111,2049,20048 -j ACCEPT
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination "\$DEST:8080"
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination "\$DEST:2026"
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 8080 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 2026 -j ACCEPT
"\$IPT" -P INPUT DROP
"\$IPT" -P FORWARD DROP
"\$IPT" -P OUTPUT DROP
FW_EOF
  chmod +x /etc/start_iptables.sh
  /etc/start_iptables.sh
  save_iptables_rules
}

setup_rsyslog_server_hq_srv() {
  install_packages rsyslog logrotate
  mkdir -p /opt
  backup_file /etc/rsyslog.d/10-remote-server.conf
  cat > /etc/rsyslog.d/10-remote-server.conf <<RSYSLOG_SERVER_EOF
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")
\$template RemoteLogs,"/opt/%HOSTNAME%/%\$YEAR%-%\$MONTH%-%\$DAY%.log"
if \$fromhost-ip != '127.0.0.1' and \$fromhost-ip != '$HQ_SRV_IP' then {
  if \$syslogseverity <= 4 then {
    ?RemoteLogs
    stop
  }
}
RSYSLOG_SERVER_EOF
  cat > /etc/logrotate.d/remote-opt-logs <<'LOGROTATE_EOF'
/opt/*/*.log {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  minsize 10M
  create 0640 syslog adm
}
LOGROTATE_EOF
  service_restart_enable rsyslog
}

setup_rsyslog_client() {
  install_packages rsyslog
  backup_file /etc/rsyslog.d/90-remote-forward.conf
  printf '*.warning @%s:514\n' "$HQ_SRV_IP" > /etc/rsyslog.d/90-remote-forward.conf
  service_restart_enable rsyslog
}

setup_ansible_task8_br_srv() {
  install_packages ansible sshpass
  mkdir -p /etc/ansible/PC-INFO /etc/ansible/playbook
  backup_file /etc/ansible/hosts
  cat > /etc/ansible/hosts <<ANSIBLE_HOSTS_EOF
[pc]
hq-srv ansible_host=$HQ_SRV_IP ansible_port=$SSH_SERVER_PORT ansible_user=$SSH_SERVER_USER ansible_password=$SSH_SERVER_PASSWORD
hq-cli ansible_host=$HQ_CLI_IP ansible_port=$HQ_CLI_ANSIBLE_PORT ansible_user=$HQ_CLI_ANSIBLE_USER ansible_password=$HQ_CLI_ANSIBLE_PASSWORD
ANSIBLE_HOSTS_EOF
  cat > /etc/ansible/playbook/get_hostname_address.yml <<'ANSIBLE_PLAYBOOK_EOF'
- name: collect host inventory
  hosts: pc
  gather_facts: yes
  tasks:
    - name: write report on BR-SRV
      copy:
        dest: /etc/ansible/PC-INFO/{{ inventory_hostname }}.yml
        content: |
          computer_name: {{ ansible_hostname }}
          ip_address: {{ ansible_default_ipv4.address | default('N/A') }}
      delegate_to: localhost
ANSIBLE_PLAYBOOK_EOF
}

setup_cups_hq_srv() {
  install_packages cups cups-pdf printer-driver-cups-pdf cups-client
  /usr/sbin/usermod -aG lpadmin "$SSH_SERVER_USER" 2>/dev/null || true
  /usr/sbin/cupsctl --share-printers --remote-any || true
  service_restart_enable cups
}

setup_cups_hq_cli() {
  install_packages cups-client
  lpadmin -x Virtual_PDF_Printer 2>/dev/null || true
  lpadmin -p Virtual_PDF_Printer -E -v "ipp://hq-srv.$DOMAIN_LOWER/printers/CUPS-PDF" -m everywhere || true
  lpoptions -d Virtual_PDF_Printer || true
}

setup_borg_storage_hq_cli() {
  install_packages borgbackup openssh-server
  /usr/sbin/useradd -m -s /bin/bash backupsvc 2>/dev/null || true
  passwd -l backupsvc 2>/dev/null || true
  mkdir -p /backup/irpo/borg /home/backupsvc/.ssh
  chmod 755 /backup /backup/irpo /backup/irpo/borg
  touch /home/backupsvc/.ssh/authorized_keys
  chmod 700 /home/backupsvc/.ssh
  chmod 600 /home/backupsvc/.ssh/authorized_keys
  chown -R backupsvc:backupsvc /backup/irpo /home/backupsvc/.ssh
  service_restart_enable ssh
}

setup_borg_hq_srv() {
  install_packages borgbackup mariadb-client openssh-client gzip
  /usr/sbin/useradd -m -s /bin/bash irpoadmin 2>/dev/null || true
  echo "irpoadmin:$ADMIN_PASSWORD" | chpasswd
  printf 'irpoadmin ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/irpoadmin
  chmod 440 /etc/sudoers.d/irpoadmin
  sudo -u irpoadmin mkdir -p /home/irpoadmin/.ssh
  [ -f /home/irpoadmin/.ssh/borg_irpo ] || sudo -u irpoadmin ssh-keygen -t ed25519 -N "" -f /home/irpoadmin/.ssh/borg_irpo
  log_warn "Borg key created. Add /home/irpoadmin/.ssh/borg_irpo.pub to backupsvc@HQ-CLI authorized_keys before real backup."
}

setup_fail2ban_hq_srv() {
  install_packages fail2ban
  backup_file /etc/fail2ban/jail.local
  cat > /etc/fail2ban/jail.local <<'FAIL2BAN_EOF'
[DEFAULT]
bantime = 60
findtime = 600
maxretry = 3
backend = auto
banaction = iptables-multiport
action = %(action_)s

[sshd]
enabled = true
port = 2026
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 60
findtime = 600
FAIL2BAN_EOF
  service_restart_enable fail2ban
}

setup_monitoring_dns_hq_srv() {
  local zone_file="/etc/bind/zones/db.$DOMAIN_LOWER"
  [ -f "$zone_file" ] || { log_warn "DNS zone file not found: $zone_file"; return 0; }
  ensure_line "$zone_file" "mon IN CNAME hq-srv.$DOMAIN_LOWER."
  restart_service_any bind9 named || true
}

setup_isp_https_proxy() {
  install_packages nginx apache2-utils openssl
  mkdir -p /etc/nginx/ssl
  [ -f /etc/nginx/ssl/$DOMAIN_LOWER.key ] || openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout /etc/nginx/ssl/$DOMAIN_LOWER.key \
    -out /etc/nginx/ssl/$DOMAIN_LOWER.crt \
    -subj "/CN=*.$DOMAIN_LOWER" >/dev/null 2>&1 || true
  htpasswd -bc /etc/nginx/.htpasswd WEB "$ADMIN_PASSWORD" >/dev/null 2>&1 || true
  service_restart_enable nginx
}

case "$ROLE" in
  ISP)
    if [ "$MODULE3_ORCHESTRATE_FROM_ISP" = "yes" ] && [ "${MODULE3_ORCHESTRATED:-no}" != "1" ]; then
      orchestrate_module3_from_isp
    else
      install_module3_packages_local
      setup_isp_https_proxy || true
    fi
    ;;
  BR-SRV)
    install_module3_packages_local
    [ "$MODULE3_INSTALL_ONLY" = "yes" ] && { log_ok "Module 3 install-only completed for BR-SRV"; exit 0; }
    setup_import_users_br_srv
    setup_rsyslog_client
    setup_ansible_task8_br_srv
    ;;
  HQ-CLI)
    install_module3_packages_local
    [ "$MODULE3_INSTALL_ONLY" = "yes" ] && { log_ok "Module 3 install-only completed for HQ-CLI"; exit 0; }
    setup_hq_cli_pam
    setup_cups_hq_cli
    setup_borg_storage_hq_cli
    ;;
  HQ-RTR)
    install_module3_packages_local
    [ "$MODULE3_INSTALL_ONLY" = "yes" ] && { log_ok "Module 3 install-only completed for HQ-RTR"; exit 0; }
    setup_ipsec "$HQ_RTR_WAN_IP" "hq-rtr.$DOMAIN_LOWER" "$BR_RTR_WAN_IP" "br-rtr.$DOMAIN_LOWER"
    setup_firewall_router "$HQ_SRV_IP"
    setup_rsyslog_client
    ;;
  BR-RTR)
    install_module3_packages_local
    [ "$MODULE3_INSTALL_ONLY" = "yes" ] && { log_ok "Module 3 install-only completed for BR-RTR"; exit 0; }
    setup_ipsec "$BR_RTR_WAN_IP" "br-rtr.$DOMAIN_LOWER" "$HQ_RTR_WAN_IP" "hq-rtr.$DOMAIN_LOWER"
    setup_firewall_router "$BR_SRV_IP"
    setup_rsyslog_client
    ;;
  HQ-SRV)
    install_module3_packages_local
    [ "$MODULE3_INSTALL_ONLY" = "yes" ] && { log_ok "Module 3 install-only completed for HQ-SRV"; exit 0; }
    setup_cups_hq_srv
    setup_rsyslog_server_hq_srv
    setup_monitoring_dns_hq_srv
    setup_borg_hq_srv
    setup_fail2ban_hq_srv
    ;;
  *)
    log_warn "No Module 3 actions for role: $ROLE"
    ;;
esac

log_ok "Module 3 completed for role: $ROLE"
