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
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-192.168.100.1}"
HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
HQ_CLI_NET="${HQ_CLI_NET:-192.168.200.0/27}"
SSH_SERVER_USER="${SSH_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_PASSWORD:-$ADMIN_PASSWORD}"
SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-2026}"
HQ_CLI_ANSIBLE_USER="${HQ_CLI_ANSIBLE_USER:-user}"
HQ_CLI_ANSIBLE_PASSWORD="${HQ_CLI_ANSIBLE_PASSWORD:-}"
NFS_DIR="${NFS_DIR:-/raid/nfs}"
NTP_SERVER_IP="${NTP_SERVER_IP:-172.16.1.1}"
ISO_DIR="${ISO_MOUNTPOINT:-/mnt/additional}"
YANDEX_BROWSER_ENABLE="${YANDEX_BROWSER_ENABLE:-yes}"

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

prepare_iso_mount() {
  local candidate
  for candidate in "$ISO_DIR" /media/cdrom0 /mnt/additional /tmp/additional; do
    [ -d "$candidate" ] || continue
    if [ -d "$candidate/docker" ] || [ -d "$candidate/web" ] || [ -f "$candidate/Users.csv" ]; then
      ISO_DIR="$candidate"
      log_ok "Additional files found: $ISO_DIR"
      return 0
    fi
  done
  if [ -n "${ISO_PATH:-}" ] && [ -f "$ISO_PATH" ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o loop,ro "$ISO_PATH" "$ISO_DIR" || true
    if [ -d "$ISO_DIR/docker" ] || [ -d "$ISO_DIR/web" ] || [ -f "$ISO_DIR/Users.csv" ]; then
      log_ok "Additional ISO mounted: $ISO_DIR"
      return 0
    fi
  fi
  log_warn "Additional files were not found. Set ISO_PATH or mount the ISO to $ISO_DIR."
  return 1
}

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
  install_packages chrony
  backup_file /etc/chrony/chrony.conf
  cat > /etc/chrony/chrony.conf <<EOF
local stratum 5

allow 192.168.100.0/28
allow 192.168.200.0/27
allow 192.168.255.0/28
allow 172.16.0.0/16

bindaddress 0.0.0.0

driftfile /var/lib/chrony/chrony.drift

log tracking measurements statistics
logdir /var/log/chrony

rtcsync
EOF
  service_restart_enable chrony
}

setup_chrony_client() {
  install_packages chrony
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
server {
    listen 80;
    server_name web.$DOMAIN_LOWER;

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://$HQ_SRV_IP:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen 80;
    server_name docker.$DOMAIN_LOWER;

    location / {
        proxy_pass http://$BR_SRV_IP:8080;
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
}

setup_router_dnat() {
  local dest="$1"
  local wan_ip="$2"
  ensure_iptables_available
  ensure_iptables_rule nat PREROUTING -d "$wan_ip" -p tcp --dport 8080 -j DNAT --to-destination "$dest:8080"
  ensure_iptables_rule nat PREROUTING -d "$wan_ip" -p udp --dport 8080 -j DNAT --to-destination "$dest:8080"
  ensure_iptables_rule nat PREROUTING -d "$wan_ip" -p tcp --dport 80 -j DNAT --to-destination "$dest:80"
  ensure_iptables_rule nat PREROUTING -d "$wan_ip" -p tcp --dport 2026 -j DNAT --to-destination "$dest:2026"
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 8080 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p udp -d "$dest" --dport 8080 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 80 -j ACCEPT
  ensure_iptables_rule filter FORWARD -p tcp -d "$dest" --dport 2026 -j ACCEPT
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
  install_packages apache2 mariadb-server php php-mysql php-cli php-gd
  service_restart_enable mariadb
  local admin_sql_password
  admin_sql_password="$(sql_literal_escape "$ADMIN_PASSWORD")"
  sql_root "CREATE DATABASE IF NOT EXISTS webdb;"
  sql_root "CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
  sql_root "CREATE USER IF NOT EXISTS 'user'@'localhost' IDENTIFIED BY '$admin_sql_password';"
  sql_root "GRANT ALL PRIVILEGES ON webdb.* TO 'user'@'localhost'; FLUSH PRIVILEGES;"
  if prepare_iso_mount && [ -d "$ISO_DIR/web" ]; then
    [ -f "$ISO_DIR/web/dump.sql" ] && { mariadb -u root webdb < "$ISO_DIR/web/dump.sql" || mysql -u root webdb < "$ISO_DIR/web/dump.sql" || true; }
    [ -f "$ISO_DIR/web/index.php" ] && cp "$ISO_DIR/web/index.php" /var/www/html/index.php
    mkdir -p /var/www/html/images
    [ -f "$ISO_DIR/web/logo.png" ] && cp "$ISO_DIR/web/logo.png" /var/www/html/images/logo.png
  fi
  if [ -f /var/www/html/index.php ]; then
    local web_password
    web_password="$(php_double_quoted_escape "$ADMIN_PASSWORD")"
    web_password="$(sed_replacement_escape "$web_password")"
    sed -i "s/\\\$password *= *\"[^\"]*\"/\\\$password = \"$web_password\"/" /var/www/html/index.php || true
    sed -i 's/$dbname *= *"[^"]*"/$dbname = "webdb"/' /var/www/html/index.php || true
  fi
  rm -f /var/www/html/index.html
  if [ -f /etc/apache2/mods-enabled/dir.conf ]; then
    sed -i 's/DirectoryIndex .*/DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm/' /etc/apache2/mods-enabled/dir.conf
  fi
  chown -R www-data:www-data /var/www/html
  chmod -R 755 /var/www/html
  service_restart_enable apache2
}

setup_samba_dc() {
  install_packages samba krb5-user winbind smbclient
  write_krb5_conf
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
      --adminpass="$ADMIN_PASSWORD"
  fi
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
}

setup_ansible_br_srv() {
  install_packages ansible sshpass
  mkdir -p /etc/ansible
  local hq_cli_inventory
  hq_cli_inventory="hq-cli ansible_host=$HQ_CLI_IP ansible_port=22 ansible_user=$HQ_CLI_ANSIBLE_USER ansible_become=false"
  [ -n "$HQ_CLI_ANSIBLE_PASSWORD" ] && hq_cli_inventory="$hq_cli_inventory ansible_password=$HQ_CLI_ANSIBLE_PASSWORD"
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
  [ -f "$ISO_DIR/docker/mariadb_latest.tar" ] && docker load -i "$ISO_DIR/docker/mariadb_latest.tar"
  [ -f "$ISO_DIR/docker/site_latest.tar" ] && docker load -i "$ISO_DIR/docker/site_latest.tar"
  retag_docker_image_if_needed mariadb:10.11 mariadb:latest
  mkdir -p /opt/testapp
  local reset_volume="no"
  if [ -f /opt/testapp/docker-compose.yml ] && { ! grep -q "DB_USER: \"$DOCKER_DB_USER\"" /opt/testapp/docker-compose.yml || ! grep -q "DB_PASS: \"$DOCKER_DB_PASSWORD\"" /opt/testapp/docker-compose.yml || ! grep -q "MARIADB_ROOT_PASSWORD: \"$DOCKER_DB_ROOT_PASSWORD\"" /opt/testapp/docker-compose.yml; }; then
    reset_volume="yes"
  fi
  backup_file /opt/testapp/docker-compose.yml
  cat > /opt/testapp/docker-compose.yml <<EOF
version: '3.8'
services:
  database:
    container_name: db
    image: mariadb:10.11
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
    image: site:latest
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
  cd /opt/testapp
  if [ "$reset_volume" = "yes" ]; then
    log_warn "Docker compose DB settings changed; resetting old testapp volume"
    docker_compose_down_reset || true
  fi
  docker_compose_up
  ensure_docker_database || true
  docker restart testapp >/dev/null 2>&1 || true
  local ok=0
  for _ in $(seq 1 24); do
    if curl -fsS http://127.0.0.1:8080 >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 5
  done
  [ "$ok" -eq 1 ] || log_warn "Docker app did not answer on http://127.0.0.1:8080 yet"
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
  install_packages curl gnupg ca-certificates
  mkdir -p /usr/share/keyrings "$TMP_DIR"
  local key_tmp="$TMP_DIR/yandex-browser-key.gpg"
  rm -f /usr/share/keyrings/yandex-browser.gpg
  if curl -fsSL -o "$key_tmp" https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG \
    && gpg --batch --yes --dearmor -o /usr/share/keyrings/yandex-browser.gpg "$key_tmp"; then
    echo "deb [signed-by=/usr/share/keyrings/yandex-browser.gpg] https://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    apt_get_retry update || true
    install_packages yandex-browser-stable || log_warn "Yandex Browser package was not installed"
  else
    log_warn "Could not fetch Yandex Browser repository key"
  fi
  rm -f "$key_tmp"
}

setup_hq_cli_domain_nfs() {
  setup_chrony_client
  write_krb5_conf
  printf 'krb5-config krb5-config/default_realm string %s\n' "$REALM_UPPER" | debconf-set-selections 2>/dev/null || true
  printf 'krb5-config krb5-config/kerberos_servers string br-srv.%s\n' "$DOMAIN_LOWER" | debconf-set-selections 2>/dev/null || true
  printf 'krb5-config krb5-config/admin_server string br-srv.%s\n' "$DOMAIN_LOWER" | debconf-set-selections 2>/dev/null || true
  install_packages realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin packagekit krb5-user nfs-common oddjob oddjob-mkhomedir
  echo "$ADMIN_PASSWORD" | realm join -U Administrator "$DOMAIN_LOWER" || log_warn "realm join failed or already joined"
  configure_hq_domain_sudoers
  pam-auth-update --enable mkhomedir --force 2>/dev/null || true
  mkdir -p /mnt/nfs
  mountpoint -q /mnt/nfs || mount "$HQ_SRV_IP:/raid/nfs" /mnt/nfs || log_warn "NFS mount failed; fstab still configured"
  ensure_line /etc/fstab "$HQ_SRV_IP:/raid/nfs /mnt/nfs nfs defaults,_netdev 0 0"
  setup_yandex_browser_client
}

case "$ROLE" in
  ISP)
    run_if_needed "ISP chrony server" "systemctl is-active --quiet chrony" setup_chrony_server
    run_if_needed "ISP nginx reverse proxy" "systemctl is-active --quiet nginx && grep -q 'server_name web.$DOMAIN_LOWER;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null && grep -q 'server_name docker.$DOMAIN_LOWER;' /etc/nginx/sites-available/reverse_proxy.conf 2>/dev/null" setup_isp_proxy
    ;;
  HQ-RTR)
    run_if_needed "HQ-RTR chrony client" "systemctl is-active --quiet chrony" setup_chrony_client
    run_if_needed "HQ-RTR DNAT" "iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $HQ_SRV_IP:80' && iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $HQ_SRV_IP:8080'" "setup_router_dnat '$HQ_SRV_IP' '$HQ_RTR_WAN_IP'"
    ;;
  BR-RTR)
    run_if_needed "BR-RTR chrony client" "systemctl is-active --quiet chrony" setup_chrony_client
    run_if_needed "BR-RTR DNAT" "iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $BR_SRV_IP:80' && iptables -t nat -S 2>/dev/null | grep -q -- '--to-destination $BR_SRV_IP:8080'" "setup_router_dnat '$BR_SRV_IP' '$BR_RTR_WAN_IP'"
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
    run_if_needed "BR-SRV Ansible config" "[ -f /etc/ansible/hosts ] && grep -q 'hq-srv' /etc/ansible/hosts" setup_ansible_br_srv
    run_if_needed "BR-SRV Docker app" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx testapp && grep -q 'DB_USER: \"$DOCKER_DB_USER\"' /opt/testapp/docker-compose.yml 2>/dev/null && grep -q 'DB_PASS: \"$DOCKER_DB_PASSWORD\"' /opt/testapp/docker-compose.yml 2>/dev/null" setup_docker_app_br_srv
    ;;
  HQ-CLI)
    run_if_needed "HQ-CLI domain and NFS client" "realm list 2>/dev/null | grep -qi '$DOMAIN_LOWER' && grep -q '$HQ_SRV_IP:/raid/nfs' /etc/fstab 2>/dev/null" setup_hq_cli_domain_nfs
    ;;
  *)
    log_skip "No Module 2 actions for role: $ROLE"
    ;;
esac

log_ok "Module 2 completed for role: $ROLE"
