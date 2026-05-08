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
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-2026}"
SSH_CLIENT_PORT="${SSH_CLIENT_PORT:-22}"
ISO_DIR="${ISO_MOUNTPOINT:-/mnt/additional}"

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

service_restart_enable() {
  enable_service "$1"
  restart_service "$1"
}

prepare_iso_mount() {
  local candidate
  for candidate in "$ISO_DIR" /media/cdrom0 /mnt/additional /tmp/additional; do
    [ -d "$candidate" ] || continue
    if [ -f "$candidate/Users.csv" ] || [ -d "$candidate/users" ]; then
      ISO_DIR="$candidate"
      return 0
    fi
  done
  if [ -n "${ISO_PATH:-}" ] && [ -f "$ISO_PATH" ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o loop,ro "$ISO_PATH" "$ISO_DIR" || true
    [ -f "$ISO_DIR/Users.csv" ] && return 0
  fi
  return 1
}

setup_import_users_br_srv() {
  install_packages samba-common-bin
  prepare_iso_mount || { log_warn "Users.csv was not found in Additional ISO"; return 0; }
  local csv="$ISO_DIR/Users.csv"
  [ -f "$csv" ] || { log_warn "Users.csv was not found: $csv"; return 0; }
  cat > /opt/import_users.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CSV_FILE="${1:-/mnt/additional/Users.csv}"
[ -f "$CSV_FILE" ] || { echo "CSV not found: $CSV_FILE"; exit 1; }
tail -n +2 "$CSV_FILE" | while IFS=';' read -r first_name last_name role phone ou street zip city country password rest
do
  username="$(printf '%s%s' "${first_name:0:1}" "$last_name" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:][:punct:]')"
  password="$(printf '%s' "${password:-}" | tr -d '[:space:]')"
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
  chmod +x /opt/import_users.sh
  /opt/import_users.sh "$csv"
}

setup_hq_cli_pam() {
  install_packages libpam-modules
  grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session || \
    printf 'session required pam_mkhomedir.so skel=/etc/skel/ umask=0077\n' >> /etc/pam.d/common-session
}

setup_ipsec() {
  local left_ip="$1"
  local left_id="$2"
  local right_ip="$3"
  local right_id="$4"
  install_packages strongswan strongswan-starter strongswan-swanctl
  backup_file /etc/ipsec.conf
  cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
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
    esp=aes256-sha2_256!
    ike=aes256-sha2_256-modp2048!
    leftprotoport=gre
    rightprotoport=gre
    leftfirewall=yes
    rightfirewall=yes
EOF
  backup_file /etc/ipsec.secrets
  cat > /etc/ipsec.secrets <<EOF
@$left_id @$right_id : PSK "$ADMIN_PASSWORD"
EOF
  chmod 600 /etc/ipsec.secrets
  systemctl enable ipsec 2>/dev/null || systemctl enable strongswan-starter 2>/dev/null || true
  restart_service ipsec
  restart_service strongswan-starter
}

setup_firewall_router() {
  local dest="$1"
  local wan_if="${NAT_OUT_IFACE:-${WAN_IFACE:-ens33}}"
  local nat_lans="${NAT_LAN_CIDRS:-}"
  local nat_excludes="${NAT_EXCLUDE_CIDRS:-}"
  ensure_iptables_available
  backup_file /etc/start_iptables.sh
  cat > /etc/start_iptables.sh <<EOF
#!/usr/bin/env bash
set -e
IPT="\$(command -v iptables 2>/dev/null || printf '/usr/sbin/iptables')"
WAN_IF="$wan_if"
DEST="$dest"
NAT_LAN_CIDRS="$nat_lans"
NAT_EXCLUDE_CIDRS="$nat_excludes"

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
"\$IPT" -A INPUT -p icmp -j ACCEPT
"\$IPT" -A FORWARD -p icmp -j ACCEPT
"\$IPT" -A OUTPUT -p icmp -j ACCEPT
"\$IPT" -A INPUT -p ospf -j ACCEPT
"\$IPT" -A FORWARD -p ospf -j ACCEPT
"\$IPT" -A OUTPUT -p ospf -j ACCEPT
"\$IPT" -A INPUT -p gre -j ACCEPT
"\$IPT" -A FORWARD -p gre -j ACCEPT
"\$IPT" -A OUTPUT -p gre -j ACCEPT
"\$IPT" -A INPUT -p 50 -j ACCEPT
"\$IPT" -A OUTPUT -p 50 -j ACCEPT
"\$IPT" -A FORWARD -p 50 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 500 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 4500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 4500 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 53 -j ACCEPT
"\$IPT" -A INPUT -p tcp --dport 53 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 53 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 53 -j ACCEPT
"\$IPT" -A INPUT -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 22,2026,80,443,8080 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 123 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 123 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 123 -j ACCEPT
"\$IPT" -A INPUT -p udp --dport 514 -j ACCEPT
"\$IPT" -A INPUT -p tcp --dport 514 -j ACCEPT
"\$IPT" -A OUTPUT -p udp --dport 514 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp --dport 514 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 514 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 514 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 88,135,139,389,445,464,636,3268,3269 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 88,137,138,389,464 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 111,2049,20048 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 111,2049,20048 -j ACCEPT
"\$IPT" -A INPUT -p tcp -m multiport --dports 631,10050,10051 -j ACCEPT
"\$IPT" -A OUTPUT -p tcp -m multiport --dports 631,10050,10051 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 631,10050,10051 -j ACCEPT

"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination "\$DEST:8080"
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination "\$DEST:2026"
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 8080 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -d "\$DEST" --dport 2026 -j ACCEPT

for cidr in \$NAT_LAN_CIDRS; do
  for exclude in \$NAT_EXCLUDE_CIDRS; do
    "\$IPT" -t nat -A POSTROUTING -s "\$cidr" -d "\$exclude" -j RETURN
  done
  [ -n "\$WAN_IF" ] && "\$IPT" -t nat -A POSTROUTING -s "\$cidr" -o "\$WAN_IF" -j MASQUERADE
done

"\$IPT" -P INPUT DROP
"\$IPT" -P FORWARD DROP
"\$IPT" -P OUTPUT DROP
EOF
  chmod +x /etc/start_iptables.sh
  /etc/start_iptables.sh
  save_iptables_rules
}

setup_rsyslog_server_hq_srv() {
  install_packages rsyslog
  mkdir -p /opt
  backup_file /etc/rsyslog.d/10-remote-server.conf
  cat > /etc/rsyslog.d/10-remote-server.conf <<EOF
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
EOF
  service_restart_enable rsyslog
}

setup_rsyslog_client() {
  install_packages rsyslog
  backup_file /etc/rsyslog.d/90-remote-forward.conf
  printf '*.* @%s:514\n' "$HQ_SRV_IP" > /etc/rsyslog.d/90-remote-forward.conf
  service_restart_enable rsyslog
}

setup_ansible_task8_br_srv() {
  install_packages ansible sshpass
  mkdir -p /etc/ansible/PC-INFO /etc/ansible/playbook /etc/ansible/router-backups
  backup_file /etc/ansible/hosts
  cat > /etc/ansible/hosts <<EOF
[servers]
hq-srv ansible_host=$HQ_SRV_IP ansible_port=$SSH_SERVER_PORT ansible_user=$SSH_SERVER_USER ansible_password=$SSH_SERVER_PASSWORD
hq-cli ansible_host=$HQ_CLI_IP ansible_port=$SSH_CLIENT_PORT ansible_user=user ansible_password=root ansible_become=false

[routers]
hq-rtr ansible_host=$HQ_RTR_HQ_IP ansible_port=$SSH_ROUTER_PORT ansible_user=$SSH_ROUTER_USER ansible_password=$SSH_ROUTER_PASSWORD
br-rtr ansible_host=$BR_RTR_LAN_IP ansible_port=$SSH_ROUTER_PORT ansible_user=$SSH_ROUTER_USER ansible_password=$SSH_ROUTER_PASSWORD

[all:children]
servers
routers
EOF
  cat > /etc/ansible/playbook/get_hostname_address.yml <<'EOF'
- name: collect host inventory
  hosts: hq-srv,hq-cli
  gather_facts: yes
  tasks:
    - name: write report on BR-SRV
      copy:
        dest: /etc/ansible/PC-INFO/{{ ansible_hostname }}.yml
        content: |
          computer_name: {{ ansible_hostname }}
          ip_address: {{ ansible_default_ipv4.address | default('N/A') }}
      delegate_to: localhost
      run_once: false
EOF
}

setup_cups_hq_srv() {
  install_packages cups cups-pdf printer-driver-cups-pdf
  /usr/sbin/usermod -aG lpadmin "$SSH_SERVER_USER" 2>/dev/null || true
  /usr/sbin/cupsctl --share-printers --remote-any || true
  service_restart_enable cups
}

setup_cups_hq_cli() {
  install_packages cups-client
  lpadmin -x Virtual_PDF_Printer 2>/dev/null || true
  lpadmin -p Virtual_PDF_Printer -E -v "ipp://hq-srv.$DOMAIN_LOWER/printers/CUPS-PDF" -m everywhere || true
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
  cat > /usr/local/sbin/irpo-backup-etc.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export BORG_RSH="ssh -i /home/irpoadmin/.ssh/borg_irpo -o IdentitiesOnly=yes"
export BORG_PASSPHRASE='P@ssw0rd'
REPO="backupsvc@192.168.200.2:/backup/irpo/borg"
ARCH="irpo-etc-$(date +%F_%H-%M-%S)"
borg create --stats --compression zstd,6 "$REPO::$ARCH" /etc
EOF
  cat > /usr/local/sbin/irpo-backup-webdb.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export BORG_RSH="ssh -i /home/irpoadmin/.ssh/borg_irpo -o IdentitiesOnly=yes"
export BORG_PASSPHRASE='P@ssw0rd'
REPO="backupsvc@192.168.200.2:/backup/irpo/borg"
TS="$(date +%F_%H-%M-%S)"
DUMP="/tmp/webdb_${TS}.sql.gz"
if command -v mariadb-dump >/dev/null 2>&1; then
  mariadb-dump -u root --single-transaction --routines --triggers webdb | gzip -9 > "$DUMP"
else
  mysqldump -u root --single-transaction --routines --triggers webdb | gzip -9 > "$DUMP"
fi
borg create --stats --compression zstd,6 "$REPO::irpo-webdb-${TS}" "$DUMP"
rm -f "$DUMP"
EOF
  chmod +x /usr/local/sbin/irpo-backup-etc.sh /usr/local/sbin/irpo-backup-webdb.sh
  chown irpoadmin:irpoadmin /usr/local/sbin/irpo-backup-etc.sh /usr/local/sbin/irpo-backup-webdb.sh
  log_warn "Add /home/irpoadmin/.ssh/borg_irpo.pub to /home/backupsvc/.ssh/authorized_keys on HQ-CLI before running Borg backups."
}

setup_fail2ban_hq_srv() {
  install_packages fail2ban
  backup_file /etc/fail2ban/jail.local
  cat > /etc/fail2ban/jail.local <<'EOF'
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

[sshd-ddos]
enabled = false
EOF
  service_restart_enable fail2ban
}

setup_monitoring_dns_hq_srv() {
  local zone_file="/etc/bind/zones/db.$DOMAIN_LOWER"
  [ -f "$zone_file" ] || { log_warn "DNS zone file not found for mon CNAME: $zone_file"; return 0; }
  ensure_line "$zone_file" "mon IN CNAME hq-srv.$DOMAIN_LOWER."
  restart_service_any bind9 named
}

case "$ROLE" in
  BR-SRV)
    run_if_needed "BR-SRV import users" "[ -x /opt/import_users.sh ]" setup_import_users_br_srv
    run_if_needed "BR-SRV rsyslog client" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    run_if_needed "BR-SRV ansible inventory" "[ -f /etc/ansible/playbook/get_hostname_address.yml ]" setup_ansible_task8_br_srv
    ;;
  HQ-CLI)
    run_if_needed "HQ-CLI PAM mkhomedir" "grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session 2>/dev/null" setup_hq_cli_pam
    run_if_needed "HQ-CLI CUPS printer" "lpstat -v 2>/dev/null | grep -q 'Virtual_PDF_Printer'" setup_cups_hq_cli
    run_if_needed "HQ-CLI Borg storage" "id backupsvc >/dev/null 2>&1 && [ -d /backup/irpo/borg ]" setup_borg_storage_hq_cli
    ;;
  HQ-RTR)
    run_if_needed "HQ-RTR IPsec" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null" "setup_ipsec '$HQ_RTR_WAN_IP' 'hq-rtr.$DOMAIN_LOWER' '$BR_RTR_WAN_IP' 'br-rtr.$DOMAIN_LOWER'"
    run_if_needed "HQ-RTR firewall" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST=\"$HQ_SRV_IP\"' /etc/start_iptables.sh" "setup_firewall_router '$HQ_SRV_IP'"
    run_if_needed "HQ-RTR rsyslog client" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    ;;
  BR-RTR)
    run_if_needed "BR-RTR IPsec" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null" "setup_ipsec '$BR_RTR_WAN_IP' 'br-rtr.$DOMAIN_LOWER' '$HQ_RTR_WAN_IP' 'hq-rtr.$DOMAIN_LOWER'"
    run_if_needed "BR-RTR firewall" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST=\"$BR_SRV_IP\"' /etc/start_iptables.sh" "setup_firewall_router '$BR_SRV_IP'"
    run_if_needed "BR-RTR rsyslog client" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    ;;
  HQ-SRV)
    run_if_needed "HQ-SRV CUPS server" "systemctl is-active --quiet cups && lpstat -v 2>/dev/null | grep -q 'CUPS-PDF'" setup_cups_hq_srv
    run_if_needed "HQ-SRV rsyslog server" "[ -f /etc/rsyslog.d/10-remote-server.conf ]" setup_rsyslog_server_hq_srv
    run_if_needed "HQ-SRV monitoring DNS" "grep -q '^mon IN CNAME' /etc/bind/zones/db.$DOMAIN_LOWER 2>/dev/null" setup_monitoring_dns_hq_srv
    run_if_needed "HQ-SRV Borg client scripts" "[ -x /usr/local/sbin/irpo-backup-etc.sh ] && [ -x /usr/local/sbin/irpo-backup-webdb.sh ]" setup_borg_hq_srv
    run_if_needed "HQ-SRV fail2ban" "systemctl is-active --quiet fail2ban && grep -q '^port = 2026' /etc/fail2ban/jail.local 2>/dev/null" setup_fail2ban_hq_srv
    ;;
  *)
    log_skip "No Module 3 actions for role: $ROLE"
    ;;
esac

log_ok "Module 3 completed for role: $ROLE"
