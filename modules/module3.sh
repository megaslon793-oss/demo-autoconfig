#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

# Allows ISP orchestration to run this module on remote nodes without rewriting their config.env.
if [ -n "${DEMO_FORCE_ROLE:-}" ]; then
  ROLE="$DEMO_FORCE_ROLE"
fi

ADMIN_PASSWORD="${ADMIN_PASSWORD:-P@ssw0rd}"
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
HQ_NETS="${HQ_NETS:-192.168.100.0/28 192.168.200.0/27 192.168.250.0/29}"
BR_NETS="${BR_NETS:-192.168.255.0/28}"
ALL_INTERNAL_NETS="${ALL_INTERNAL_NETS:-$HQ_NETS $BR_NETS 172.16.0.0/16 10.0.0.0/30}"
SSH_SERVER_USER="${SSH_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_PASSWORD:-$ADMIN_PASSWORD}"
SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"
SSH_CLIENT_PORT="${SSH_CLIENT_PORT:-22}"
ISO_DIR="${ISO_MOUNTPOINT:-/mnt/additional}"
USERS_CSV_PATH="${USERS_CSV_PATH:-Users.csv}"
CA_DIR="${CA_DIR:-/etc/demo-ca}"
CA_DAYS="${CA_DAYS:-30}"
MONITOR_PORT="${MONITOR_PORT:-80}"
MONITOR_USER="${MONITOR_USER:-admin}"
MONITOR_PASSWORD="${MONITOR_PASSWORD:-$ADMIN_PASSWORD}"
FAIL2BAN_SSH_PORT="${FAIL2BAN_SSH_PORT:-2026}"
BACKUP_REPO="${BACKUP_REPO:-backupsvc@$HQ_CLI_IP:/backup/irpo/borg}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-$ADMIN_PASSWORD}"
IPSEC_PSK="${IPSEC_PSK:-$ADMIN_PASSWORD}"

ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

ensure_block() {
  local file="$1" marker="$2" content="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "BEGIN $marker" "$file"; then
    awk -v marker="$marker" -v content="$content" '
      $0 ~ "BEGIN " marker { print; print content; skip=1; next }
      $0 ~ "END " marker { skip=0; print; next }
      !skip { print }
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  else
    {
      printf '\n# BEGIN %s\n' "$marker"
      printf '%s\n' "$content"
      printf '# END %s\n' "$marker"
    } >> "$file"
  fi
}

run_if_needed() {
  local title="$1" check_cmd="$2" action="$3"
  if eval "$check_cmd"; then
    log_skip "$title"
  else
    log_ok "$title"
    eval "$action"
  fi
}

restart_enable_any() {
  enable_service_any "$@"
  restart_service_any "$@"
}

service_restart_enable() {
  enable_service "$1"
  restart_service "$1"
}

prepare_iso_mount() {
  local candidate
  for candidate in "$ISO_DIR" /mnt/additional /media/cdrom /media/cdrom0 /tmp/additional; do
    [ -d "$candidate" ] || continue
    if [ -f "$candidate/$USERS_CSV_PATH" ] || [ -f "$candidate/Users.csv" ] || [ -d "$candidate/docker" ] || [ -d "$candidate/playbook" ]; then
      ISO_DIR="$candidate"
      log_ok "Additional ISO directory detected: $ISO_DIR"
      return 0
    fi
  done
  if [ -n "${ISO_PATH:-}" ] && [ -f "$ISO_PATH" ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o loop,ro "$ISO_PATH" "$ISO_DIR" || true
    [ -d "$ISO_DIR" ] && return 0
  fi
  if [ -b /dev/sr0 ]; then
    mkdir -p "$ISO_DIR"
    mountpoint -q "$ISO_DIR" || mount -o ro /dev/sr0 "$ISO_DIR" || true
    [ -d "$ISO_DIR" ] && return 0
  fi
  return 1
}

find_iso_file() {
  local rel="$1" path
  prepare_iso_mount || true
  for path in \
    "$ISO_DIR/$rel" \
    "$ISO_DIR/$(basename "$rel")" \
    "/mnt/additional/$rel" \
    "/tmp/additional/$rel"; do
    [ -f "$path" ] && { printf '%s' "$path"; return 0; }
  done
  return 1
}

normalize_ou_name() {
  local ou="$1"
  ou="${ou//$'\r'/}"
  ou="${ou#OU=}"
  ou="${ou%%,DC=*}"
  printf '%s' "$ou" | xargs
}

setup_import_users_br_srv() {
  install_packages samba-common-bin
  local csv
  csv="$(find_iso_file "$USERS_CSV_PATH" || true)"
  [ -n "$csv" ] || csv="$(find_iso_file Users.csv || true)"
  [ -n "$csv" ] || { log_warn "Users.csv not found in Additional ISO. Import skipped."; return 0; }

  cat > /opt/import_users_module3.sh <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
CSV_FILE="${1:?Usage: import_users_module3.sh users.csv}"
BASE_DN="${2:-DC=au-team,DC=irpo}"
[ -f "$CSV_FILE" ] || { echo "CSV not found: $CSV_FILE"; exit 1; }

normalize_ou() {
  local ou="$1"
  ou="${ou//$'\r'/}"
  ou="${ou#OU=}"
  ou="${ou%%,DC=*}"
  printf '%s' "$ou" | xargs
}

make_username() {
  local first="$1" last="$2"
  printf '%s.%s' "$first" "$last" | tr '[:upper:]' '[:lower:]' | tr -d ' '
}

# Create OU from fifth CSV field.
awk -F ';' 'NR>1 {gsub("\r","",$5); if($5!="") print $5}' "$CSV_FILE" | sort -u | while IFS= read -r raw_ou; do
  ou="$(normalize_ou "$raw_ou")"
  [ -n "$ou" ] || continue
  if samba-tool ou list 2>/dev/null | tr -d '\r' | grep -Fxq "OU=$ou"; then
    echo "[SKIP] OU exists: $ou"
  else
    echo "[ADD] OU: $ou"
    samba-tool ou add "OU=$ou,$BASE_DN" || true
  fi
done

# Expected fields: First Name;Last Name;Role;Phone;OU;Street;ZIP;City;Country;Password
tail -n +2 "$CSV_FILE" | while IFS=';' read -r first last role phone raw_ou street zip city country password rest; do
  first="${first//$'\r'/}"; last="${last//$'\r'/}"; role="${role//$'\r'/}"
  phone="${phone//$'\r'/}"; password="${password//$'\r'/}"
  ou="$(normalize_ou "$raw_ou")"
  username="$(make_username "$first" "$last")"
  [ -n "$username" ] || continue
  [ -n "$password" ] || { echo "[WARN] empty password for $username, skipped"; continue; }
  if samba-tool user show "$username" >/dev/null 2>&1; then
    echo "[SKIP] user exists: $username"
    continue
  fi
  echo "[ADD] user: $username OU=$ou"
  if [ -n "$ou" ]; then
    samba-tool user add "$username" "$password" \
      --given-name="$first" \
      --surname="$last" \
      --telephone-number="$phone" \
      --job-title="$role" \
      --userou="OU=$ou,$BASE_DN"
  else
    samba-tool user add "$username" "$password" \
      --given-name="$first" \
      --surname="$last" \
      --telephone-number="$phone" \
      --job-title="$role"
  fi
  samba-tool user setexpiry "$username" --noexpiry >/dev/null 2>&1 || true
done
SCRIPT
  chmod +x /opt/import_users_module3.sh
  /opt/import_users_module3.sh "$csv" "DC=${DOMAIN_LOWER%%.*},DC=${DOMAIN_LOWER#*.}"
}

setup_hq_cli_domain_login() {
  install_packages libpam-modules
  if ! grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session; then
    backup_file /etc/pam.d/common-session
    printf 'session required pam_mkhomedir.so skel=/etc/skel/ umask=0077\n' >> /etc/pam.d/common-session
  fi
  log_ok "PAM mkhomedir enabled for domain users"
}

openssl_supports_gost() {
  openssl list -public-key-algorithms 2>/dev/null | grep -qi 'gost\|gostr3410'
}

setup_ca_hq_srv() {
  install_packages openssl ca-certificates apache2
  mkdir -p "$CA_DIR" "$CA_DIR/private" "$CA_DIR/certs" "$CA_DIR/csr" "$CA_DIR/out"
  chmod 700 "$CA_DIR/private"
  if [ ! -f "$CA_DIR/private/ca.key" ]; then
    if openssl_supports_gost; then
      log_ok "OpenSSL GOST support detected. Creating GOST-like CA key if provider accepts it."
      openssl genpkey -algorithm gost2012_256 -out "$CA_DIR/private/ca.key" 2>/dev/null || \
        openssl genrsa -out "$CA_DIR/private/ca.key" 4096
    else
      log_warn "GOST provider/engine is not available. CA will be RSA fallback. Install GOST OpenSSL engine/provider if strict domestic crypto is required."
      openssl genrsa -out "$CA_DIR/private/ca.key" 4096
    fi
    chmod 600 "$CA_DIR/private/ca.key"
  fi
  if [ ! -f "$CA_DIR/certs/ca.crt" ]; then
    openssl req -x509 -new -nodes -key "$CA_DIR/private/ca.key" -sha256 -days 365 \
      -subj "/C=RU/O=IRPO/OU=Demo/CN=IRPO Demo CA" \
      -out "$CA_DIR/certs/ca.crt"
  fi
  issue_cert web.au-team.irpo
  issue_cert docker.au-team.irpo
  mkdir -p /var/www/html
  cp -f "$CA_DIR/certs/ca.crt" /var/www/html/demo-ca.crt
  tar -C "$CA_DIR" -czf "$CA_DIR/out/nginx-web-docker-certs.tar.gz" certs private 2>/dev/null || true
  log_ok "CA ready. CA cert: /var/www/html/demo-ca.crt; cert archive: $CA_DIR/out/nginx-web-docker-certs.tar.gz"
}

issue_cert() {
  local name="$1"
  local key="$CA_DIR/private/$name.key"
  local csr="$CA_DIR/csr/$name.csr"
  local crt="$CA_DIR/certs/$name.crt"
  local ext="$CA_DIR/csr/$name.ext"
  [ -f "$key" ] || openssl genrsa -out "$key" 2048
  chmod 600 "$key"
  cat > "$ext" <<EOF_EXT
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$name
EOF_EXT
  if [ ! -f "$crt" ]; then
    openssl req -new -key "$key" -subj "/C=RU/O=IRPO/OU=Web/CN=$name" -out "$csr"
    openssl x509 -req -in "$csr" -CA "$CA_DIR/certs/ca.crt" -CAkey "$CA_DIR/private/ca.key" \
      -CAcreateserial -out "$crt" -days "$CA_DAYS" -sha256 -extfile "$ext"
  fi
}

setup_ca_trust_hq_cli() {
  install_packages ca-certificates curl
  local src=""
  if [ -f "$ISO_DIR/demo-ca.crt" ]; then
    src="$ISO_DIR/demo-ca.crt"
  else
    src="/tmp/demo-ca.crt"
    curl -fsS "http://$HQ_SRV_IP/demo-ca.crt" -o "$src" || curl -fsS "http://hq-srv.$DOMAIN_LOWER/demo-ca.crt" -o "$src" || true
  fi
  [ -f "$src" ] || { log_warn "CA certificate not found. Copy demo-ca.crt from HQ-SRV to HQ-CLI or make http://$HQ_SRV_IP/demo-ca.crt reachable."; return 0; }
  cp -f "$src" /usr/local/share/ca-certificates/demo-ca.crt
  update-ca-certificates
  log_ok "Demo CA trusted on HQ-CLI"
}

setup_nginx_https_isp() {
  install_packages nginx apache2-utils
  mkdir -p /etc/nginx/demo-certs
  local archive=""
  for archive in "$ISO_DIR/nginx-web-docker-certs.tar.gz" "$ISO_DIR/docker/nginx-web-docker-certs.tar.gz" "/tmp/nginx-web-docker-certs.tar.gz" "$CA_DIR/out/nginx-web-docker-certs.tar.gz"; do
    [ -f "$archive" ] && break
    archive=""
  done
  if [ -n "$archive" ]; then
    tar -xzf "$archive" -C /etc/nginx/demo-certs --strip-components=0 || true
  fi
  if [ ! -f /etc/nginx/demo-certs/certs/web.au-team.irpo.crt ] || [ ! -f /etc/nginx/demo-certs/private/web.au-team.irpo.key ]; then
    log_warn "Nginx HTTPS certs not found. Copy $CA_DIR/out/nginx-web-docker-certs.tar.gz from HQ-SRV to /tmp or Additional.iso on ISP."
    return 0
  fi
  htpasswd -bBc /etc/nginx/.htpasswd "$MONITOR_USER" "$MONITOR_PASSWORD" >/dev/null 2>&1 || true
  backup_file /etc/nginx/sites-available/demo-https-proxy
  cat > /etc/nginx/sites-available/demo-https-proxy <<EOF_NGINX
server {
    listen 443 ssl;
    server_name web.$DOMAIN_LOWER;
    ssl_certificate /etc/nginx/demo-certs/certs/web.$DOMAIN_LOWER.crt;
    ssl_certificate_key /etc/nginx/demo-certs/private/web.$DOMAIN_LOWER.key;
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / { proxy_pass http://$HQ_RTR_WAN_IP:8080; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
}
server {
    listen 443 ssl;
    server_name docker.$DOMAIN_LOWER;
    ssl_certificate /etc/nginx/demo-certs/certs/docker.$DOMAIN_LOWER.crt;
    ssl_certificate_key /etc/nginx/demo-certs/private/docker.$DOMAIN_LOWER.key;
    location / { proxy_pass http://$BR_RTR_WAN_IP:8080; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
}
server {
    listen 80;
    server_name web.$DOMAIN_LOWER docker.$DOMAIN_LOWER;
    return 301 https://\$host\$request_uri;
}
EOF_NGINX
  ln -sf /etc/nginx/sites-available/demo-https-proxy /etc/nginx/sites-enabled/demo-https-proxy
  nginx -t
  restart_enable_any nginx
}

setup_ipsec_transport_gre() {
  local left_ip="$1" left_id="$2" right_ip="$3" right_id="$4"
  install_packages strongswan strongswan-starter
  backup_file /etc/ipsec.conf
  cat > /etc/ipsec.conf <<EOF_IPSEC
config setup
    uniqueids=no
    charondebug="ike 1, knl 1, cfg 1"

conn %default
    keyexchange=ikev2
    authby=psk
    leftauth=psk
    rightauth=psk
    ike=aes256-sha256-modp2048!
    esp=aes256-sha256!
    dpdaction=restart
    closeaction=restart
    auto=start

conn gre-encrypt
    type=transport
    left=$left_ip
    leftid=@$left_id
    right=$right_ip
    rightid=@$right_id
    leftprotoport=gre
    rightprotoport=gre
EOF_IPSEC
  backup_file /etc/ipsec.secrets
  cat > /etc/ipsec.secrets <<EOF_SECRET
@$left_id @$right_id : PSK "$IPSEC_PSK"
EOF_SECRET
  chmod 600 /etc/ipsec.secrets
  restart_enable_any ipsec strongswan-starter strongswan
}

setup_firewall_router() {
  local dest="$1"
  local wan_if="${WAN_IFACE:-ens33}"
  ensure_iptables_available
  backup_file /etc/start_iptables.sh
  cat > /etc/start_iptables.sh <<EOF_FW
#!/usr/bin/env bash
set -e
IPT="\$(command -v iptables 2>/dev/null || printf '/usr/sbin/iptables')"
WAN_IF="$wan_if"
DEST="$dest"
"\$IPT" -F
"\$IPT" -t nat -F
"\$IPT" -t mangle -F
"\$IPT" -t raw -F
"\$IPT" -P INPUT DROP
"\$IPT" -P FORWARD DROP
"\$IPT" -P OUTPUT ACCEPT
"\$IPT" -A INPUT -i lo -j ACCEPT
"\$IPT" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"\$IPT" -A INPUT -p icmp -j ACCEPT
"\$IPT" -A FORWARD -p icmp -j ACCEPT
"\$IPT" -A INPUT -p gre -j ACCEPT
"\$IPT" -A OUTPUT -p gre -j ACCEPT
"\$IPT" -A INPUT -p ospf -j ACCEPT
"\$IPT" -A OUTPUT -p ospf -j ACCEPT
"\$IPT" -A INPUT -p 50 -j ACCEPT
"\$IPT" -A OUTPUT -p 50 -j ACCEPT
"\$IPT" -A INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
"\$IPT" -A OUTPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p tcp --dport 53 -j ACCEPT
"\$IPT" -A FORWARD -p udp --dport 123 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 80,443,8080,2026,631,10050,10051 -j ACCEPT
"\$IPT" -A FORWARD -p udp -m multiport --dports 137,138,514 -j ACCEPT
"\$IPT" -A FORWARD -p tcp -m multiport --dports 88,135,139,389,445,464,514,636,3268,3269 -j ACCEPT
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 8080 -j DNAT --to-destination "\$DEST:8080"
"\$IPT" -t nat -A PREROUTING -i "\$WAN_IF" -p tcp --dport 2026 -j DNAT --to-destination "\$DEST:2026"
for cidr in ${NAT_LAN_CIDRS:-$HQ_NETS $BR_NETS}; do
  [ -n "\$cidr" ] && "\$IPT" -t nat -A POSTROUTING -s "\$cidr" -o "\$WAN_IF" -j MASQUERADE
 done
/usr/sbin/iptables-save > /etc/iptables/rules.v4 2>/dev/null || /sbin/iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
EOF_FW
  chmod +x /etc/start_iptables.sh
  /etc/start_iptables.sh
  save_iptables_rules
}

setup_cups_hq_srv() {
  install_packages cups cups-pdf printer-driver-cups-pdf
  /usr/sbin/usermod -aG lpadmin "$SSH_SERVER_USER" 2>/dev/null || true
  /usr/sbin/cupsctl --share-printers --remote-any || true
  service_restart_enable cups
  if ! lpstat -v 2>/dev/null | grep -qi 'cups-pdf'; then
    lpadmin -p CUPS-PDF -E -v cups-pdf:/ -m drv:///sample.drv/generic.ppd 2>/dev/null || true
  fi
}

setup_cups_hq_cli() {
  install_packages cups cups-client
  lpadmin -x CUPS-PDF 2>/dev/null || true
  lpadmin -p CUPS-PDF -E -v "ipp://hq-srv.$DOMAIN_LOWER/printers/CUPS-PDF" -m everywhere || \
    lpadmin -p CUPS-PDF -E -v "ipp://$HQ_SRV_IP:631/printers/CUPS-PDF" -m everywhere || true
  lpoptions -d CUPS-PDF || true
  restart_enable_any cups
}

setup_rsyslog_server_hq_srv() {
  install_packages rsyslog logrotate
  mkdir -p /opt
  backup_file /etc/rsyslog.d/10-demo-remote-server.conf
  cat > /etc/rsyslog.d/10-demo-remote-server.conf <<EOF_RSYSLOG
module(load="imudp")
input(type="imudp" port="514")
module(load="imtcp")
input(type="imtcp" port="514")

\$template DemoRemoteLogs,"/opt/%HOSTNAME%/%\$YEAR%-%\$MONTH%-%\$DAY%.log"

if \$fromhost-ip != '127.0.0.1' and \$fromhost-ip != '$HQ_SRV_IP' then {
    if \$syslogseverity <= 4 then {
        ?DemoRemoteLogs
        stop
    }
}
EOF_RSYSLOG
  backup_file /etc/logrotate.d/demo-remote-opt
  cat > /etc/logrotate.d/demo-remote-opt <<'EOF_LOGROTATE'
/opt/*/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    minsize 10M
    create 0640 syslog adm
}
EOF_LOGROTATE
  service_restart_enable rsyslog
}

setup_rsyslog_client() {
  install_packages rsyslog
  backup_file /etc/rsyslog.d/90-demo-remote-forward.conf
  cat > /etc/rsyslog.d/90-demo-remote-forward.conf <<EOF_RSYSLOG_CLIENT
*.warning @$HQ_SRV_IP:514
EOF_RSYSLOG_CLIENT
  service_restart_enable rsyslog
}

setup_node_exporter() {
  install_packages prometheus-node-exporter || { log_warn "prometheus-node-exporter not available via apt. Monitoring agent skipped."; return 0; }
  restart_enable_any prometheus-node-exporter
}

setup_monitoring_hq_srv() {
  setup_node_exporter
  install_packages apache2 php libapache2-mod-php apache2-utils curl
  mkdir -p /var/www/mon
  htpasswd -bBc /etc/apache2/.mon_htpasswd "$MONITOR_USER" "$MONITOR_PASSWORD" >/dev/null 2>&1 || true
  cat > /var/www/mon/index.php <<'PHP'
<?php
$targets = [
  'HQ-SRV' => getenv('HQ_SRV_IP') ?: '127.0.0.1',
  'BR-SRV' => getenv('BR_SRV_IP') ?: '192.168.255.2',
];
function fetch_metrics($ip) {
  $url = "http://$ip:9100/metrics";
  $ctx = stream_context_create(['http' => ['timeout' => 1]]);
  $data = @file_get_contents($url, false, $ctx);
  return $data ?: '';
}
function metric_value($data, $pattern) {
  if (preg_match($pattern, $data, $m)) return (float)$m[1];
  return 0;
}
function pct_bar($pct) {
  $pct = max(0, min(100, $pct));
  return "<div class='bar'><span style='width:${pct}%'></span></div><b>".round($pct,1)."%</b>";
}
?><!doctype html><html><head><meta charset="utf-8"><title>Demo Monitoring</title><style>
body{font-family:Arial,sans-serif;margin:30px;background:#f5f5f5}.card{background:white;border:1px solid #ddd;border-radius:8px;padding:18px;margin:15px 0;box-shadow:0 2px 6px #ddd}.bar{height:18px;background:#eee;border-radius:10px;overflow:hidden;margin:5px 0}.bar span{display:block;height:100%;background:#4b8}.bad{color:#b00}.ok{color:#080}</style></head><body><h1>Monitoring au-team.irpo</h1>
<?php foreach ($targets as $name=>$ip): $m=fetch_metrics($ip); ?>
<div class="card"><h2><?=htmlspecialchars($name)?> <small><?=htmlspecialchars($ip)?></small></h2>
<?php if (!$m): ?><p class="bad">No metrics from node_exporter:9100</p><?php else:
$mem_total=metric_value($m,'/node_memory_MemTotal_bytes\s+([0-9\.]+)/');
$mem_avail=metric_value($m,'/node_memory_MemAvailable_bytes\s+([0-9\.]+)/');
$mem_pct=$mem_total>0 ? (100-($mem_avail/$mem_total*100)) : 0;
$disk_size=metric_value($m,'/node_filesystem_size_bytes\{[^}]*mountpoint="\/"[^}]*\}\s+([0-9\.]+)/');
$disk_avail=metric_value($m,'/node_filesystem_avail_bytes\{[^}]*mountpoint="\/"[^}]*\}\s+([0-9\.]+)/');
$disk_pct=$disk_size>0 ? (100-($disk_avail/$disk_size*100)) : 0;
$load=metric_value($m,'/node_load1\s+([0-9\.]+)/');
$cpu_pct=min(100,$load*25);
?><p>CPU/load: <?=pct_bar($cpu_pct)?></p><p>RAM used: <?=pct_bar($mem_pct)?></p><p>Disk / used: <?=pct_bar($disk_pct)?></p><p class="ok">metrics OK</p><?php endif; ?></div>
<?php endforeach; ?></body></html>
PHP
  backup_file /etc/apache2/sites-available/mon.conf
  cat > /etc/apache2/sites-available/mon.conf <<EOF_APACHE
<VirtualHost *:80>
    ServerName mon.$DOMAIN_LOWER
    DocumentRoot /var/www/mon
    SetEnv HQ_SRV_IP $HQ_SRV_IP
    SetEnv BR_SRV_IP $BR_SRV_IP
    <Directory /var/www/mon>
        Require ip 127.0.0.1 $HQ_CLI_NET ${HQ_NETS}
        AuthType Basic
        AuthName "Monitoring"
        AuthUserFile /etc/apache2/.mon_htpasswd
        Require valid-user
    </Directory>
</VirtualHost>
EOF_APACHE
  a2enmod auth_basic env >/dev/null 2>&1 || true
  a2ensite mon.conf >/dev/null 2>&1 || true
  restart_enable_any apache2
}

setup_monitoring_dns_hq_srv() {
  local zone_file="/etc/bind/zones/db.$DOMAIN_LOWER"
  [ -f "$zone_file" ] || zone_file="/etc/bind/zones/db.au-team.irpo"
  [ -f "$zone_file" ] || { log_warn "DNS zone file not found for mon.$DOMAIN_LOWER"; return 0; }
  backup_file "$zone_file"
  if ! grep -qE '^mon[[:space:]]+IN[[:space:]]+A' "$zone_file"; then
    printf 'mon     IN A   %s\n' "$HQ_SRV_IP" >> "$zone_file"
  fi
  if command -v named-checkzone >/dev/null 2>&1; then
    named-checkzone "$DOMAIN_LOWER" "$zone_file" || true
  fi
  restart_service_any bind9 named
}

setup_ansible_task8_br_srv() {
  install_packages ansible sshpass
  mkdir -p /etc/ansible/PC-INFO /etc/ansible/playbook
  if [ -d "$ISO_DIR/playbook" ]; then
    cp -a "$ISO_DIR/playbook/." /etc/ansible/playbook/ || true
  fi
  backup_file /etc/ansible/hosts
  cat > /etc/ansible/hosts <<EOF_HOSTS
[hq_inventory]
hq-srv ansible_host=$HQ_SRV_IP ansible_port=$SSH_SERVER_PORT ansible_user=$SSH_SERVER_USER ansible_password=$SSH_SERVER_PASSWORD ansible_become=true
hq-cli ansible_host=$HQ_CLI_IP ansible_port=$SSH_CLIENT_PORT ansible_user=${HQ_CLI_ANSIBLE_USER:-user} ansible_password=${HQ_CLI_ANSIBLE_PASSWORD:-root} ansible_become=false

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF_HOSTS
  cat > /etc/ansible/playbook/pc_info.yml <<'EOF_PLAY'
- name: collect PC info
  hosts: hq_inventory
  gather_facts: yes
  tasks:
    - name: write yml report on BR-SRV
      copy:
        dest: "/etc/ansible/PC-INFO/{{ inventory_hostname }}.yml"
        content: |
          computer_name: {{ ansible_hostname }}
          fqdn: {{ ansible_fqdn | default('N/A') }}
          ip_address: {{ ansible_default_ipv4.address | default('N/A') }}
      delegate_to: localhost
EOF_PLAY
  ansible-playbook /etc/ansible/playbook/pc_info.yml || log_warn "Ansible PC inventory playbook failed. Check SSH credentials in config.env."
}

setup_fail2ban_hq_srv() {
  install_packages fail2ban
  backup_file /etc/fail2ban/jail.local
  cat > /etc/fail2ban/jail.local <<EOF_F2B
[DEFAULT]
bantime = 60
findtime = 600
maxretry = 3
backend = auto
banaction = iptables-multiport

[sshd]
enabled = true
port = $FAIL2BAN_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 60
findtime = 600
EOF_F2B
  service_restart_enable fail2ban
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
  cat > /usr/local/sbin/irpo-backup-etc.sh <<EOF_BORG_ETC
#!/usr/bin/env bash
set -Eeuo pipefail
export BORG_RSH="ssh -i /home/irpoadmin/.ssh/borg_irpo -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
export BORG_PASSPHRASE='$BACKUP_PASSPHRASE'
REPO="$BACKUP_REPO"
ARCH="irpo-etc-\$(date +%F_%H-%M-%S)"
borg init --encryption=repokey "\$REPO" 2>/dev/null || true
borg create --stats --compression zstd,6 "\$REPO::\$ARCH" /etc
EOF_BORG_ETC
  cat > /usr/local/sbin/irpo-backup-webdb.sh <<EOF_BORG_DB
#!/usr/bin/env bash
set -Eeuo pipefail
export BORG_RSH="ssh -i /home/irpoadmin/.ssh/borg_irpo -o StrictHostKeyChecking=no -o IdentitiesOnly=yes"
export BORG_PASSPHRASE='$BACKUP_PASSPHRASE'
REPO="$BACKUP_REPO"
TS="\$(date +%F_%H-%M-%S)"
DUMP="/tmp/webdb_\${TS}.sql.gz"
if command -v mariadb-dump >/dev/null 2>&1; then
  mariadb-dump -u root --single-transaction --routines --triggers webdb | gzip -9 > "\$DUMP"
else
  mysqldump -u root --single-transaction --routines --triggers webdb | gzip -9 > "\$DUMP"
fi
borg init --encryption=repokey "\$REPO" 2>/dev/null || true
borg create --stats --compression zstd,6 "\$REPO::irpo-webdb-\${TS}" "\$DUMP"
rm -f "\$DUMP"
EOF_BORG_DB
  chmod +x /usr/local/sbin/irpo-backup-etc.sh /usr/local/sbin/irpo-backup-webdb.sh
  chown irpoadmin:irpoadmin /usr/local/sbin/irpo-backup-etc.sh /usr/local/sbin/irpo-backup-webdb.sh
  log_warn "Copy /home/irpoadmin/.ssh/borg_irpo.pub to HQ-CLI:/home/backupsvc/.ssh/authorized_keys before running backups."
}


# ---------- ISP orchestration for fast repeated tests ----------
MODULE3_ORCHESTRATE_FROM_ISP="${MODULE3_ORCHESTRATE_FROM_ISP:-yes}"
MODULE3_REMOTE_TMP_ROOT="${MODULE3_REMOTE_TMP_ROOT:-/tmp/demo-module3-remote}"
MODULE3_REMOTE_ROLES="${MODULE3_REMOTE_ROLES:-HQ-SRV HQ-CLI BR-SRV HQ-RTR BR-RTR}"

wait_for_check() {
  local attempts="$1" delay="$2" command="$3" count
  for count in $(seq 1 "$attempts"); do
    if eval "$command" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

module3_orchestration_enabled() {
  [ "${ROLE:-}" = "ISP" ] || return 1
  [ "${DEMO_SKIP_MODULE3_ORCHESTRATION:-no}" != "yes" ] || return 1
  [ "$MODULE3_ORCHESTRATE_FROM_ISP" != "no" ] || return 1
}

remote_ssh_exec() {
  local password="$1" port="$2" user="$3" host="$4"
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
  local password="$1" port="$2" user="$3" host="$4"
  remote_ssh_exec "$password" "$port" "$user" "$host" "if [ \"\$(id -u)\" -eq 0 ]; then exit 0; elif sudo -n true >/dev/null 2>&1; then exit 0; else printf '%s\n' '$password' | sudo -S -p '' true >/dev/null 2>&1; fi" >/dev/null 2>&1
}

try_connection_candidate() {
  local target_role="$1" host="$2" user="$3" password="$4" port="$5"
  [ -n "$host" ] && [ -n "$user" ] && [ -n "$password" ] && [ -n "$port" ] || return 1
  if remote_root_ready "$password" "$port" "$user" "$host"; then
    REMOTE_HOST="$host"; REMOTE_USER="$user"; REMOTE_PASSWORD="$password"; REMOTE_PORT="$port"
    log_ok "Remote root-capable SSH for $target_role: $REMOTE_HOST:$REMOTE_PORT as $REMOTE_USER"
    return 0
  fi
  return 1
}

resolve_server_connection() {
  local target_role="$1" host="$2" pw
  try_connection_candidate "$target_role" "$host" "$SSH_SERVER_USER" "$SSH_SERVER_PASSWORD" "$SSH_SERVER_PORT" && return 0
  try_connection_candidate "$target_role" "$host" "${SSH_REMOTE_USER:-user}" "${SSH_SERVER_PASSWORD:-$ADMIN_PASSWORD}" "$SSH_SERVER_PORT" && return 0
  for pw in "${SSH_SERVER_PASSWORD:-}" "${ADMIN_PASSWORD:-}" root; do
    try_connection_candidate "$target_role" "$host" root "$pw" 22 && return 0
    try_connection_candidate "$target_role" "$host" root "$pw" "$SSH_SERVER_PORT" && return 0
  done
  return 1
}

resolve_router_connection() {
  local target_role="$1" host="$2" pw
  try_connection_candidate "$target_role" "$host" "$SSH_ROUTER_USER" "$SSH_ROUTER_PASSWORD" "$SSH_ROUTER_PORT" && return 0
  try_connection_candidate "$target_role" "$host" "${SSH_ROUTER_EXTRA_USER:-user}" "${SSH_ROUTER_PASSWORD:-$ADMIN_PASSWORD}" "$SSH_ROUTER_PORT" && return 0
  for pw in "${SSH_ROUTER_PASSWORD:-}" "${ADMIN_PASSWORD:-}" root; do
    try_connection_candidate "$target_role" "$host" root "$pw" 22 && return 0
    try_connection_candidate "$target_role" "$host" root "$pw" "$SSH_ROUTER_PORT" && return 0
  done
  return 1
}

resolve_hq_cli_connection() {
  local pw
  for pw in "${HQ_CLI_ANSIBLE_PASSWORD:-}" "${ADMIN_PASSWORD:-}" "${SSH_PASSWORD:-}" root; do
    try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" root "$pw" 22 && return 0
    try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" root "$pw" "$SSH_CLIENT_PORT" && return 0
  done
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "${HQ_CLI_ANSIBLE_USER:-user}" "${HQ_CLI_ANSIBLE_PASSWORD:-root}" "${HQ_CLI_ANSIBLE_PORT:-22}" && return 0
  try_connection_candidate "HQ-CLI" "$HQ_CLI_IP" "$SSH_SERVER_USER" "$SSH_SERVER_PASSWORD" 22 && return 0
  return 1
}

wait_for_remote_ssh() {
  local target_role="$1" max_attempts="${2:-3}" delay="${3:-2}" quiet="${4:-no}" attempt
  for attempt in $(seq 1 "$max_attempts"); do
    case "$target_role" in
      HQ-SRV) resolve_server_connection "$target_role" "$HQ_SRV_IP" && return 0 ;;
      BR-SRV) resolve_server_connection "$target_role" "$BR_SRV_IP" && return 0 ;;
      HQ-RTR) resolve_router_connection "$target_role" "$HQ_RTR_WAN_IP" && return 0 ;;
      BR-RTR) resolve_router_connection "$target_role" "$BR_RTR_WAN_IP" && return 0 ;;
      HQ-CLI) resolve_hq_cli_connection && return 0 ;;
      *) log_error "Unknown remote Module 3 role: $target_role"; return 1 ;;
    esac
    sleep "$delay"
  done
  [ "$quiet" = "yes" ] || log_error "Could not reach $target_role with root-capable SSH"
  return 1
}

stream_remote_module3_role() {
  local target_role="$1" remote_dir remote_cmd remote_pw_q remote_dir_q target_q
  remote_dir="$MODULE3_REMOTE_TMP_ROOT/${target_role,,}"
  printf -v remote_pw_q '%q' "$REMOTE_PASSWORD"
  printf -v remote_dir_q '%q' "$remote_dir"
  printf -v target_q '%q' "$target_role"
  remote_cmd="remote_dir=$remote_dir_q; sudo_pw=$remote_pw_q; target_role=$target_q; rm -rf \"\$remote_dir\"; mkdir -p \"\$remote_dir\"; tar -xzf - -C \"\$remote_dir\" || { rc=\$?; rm -rf \"\$remote_dir\"; exit \$rc; }; rc=0; if [ \"\$(id -u)\" -eq 0 ]; then DEMO_SKIP_MODULE3_ORCHESTRATION=yes DEMO_FORCE_ROLE=\"\$target_role\" bash \"\$remote_dir/modules/module3.sh\" || rc=\$?; elif sudo -n true >/dev/null 2>&1; then sudo -n env DEMO_SKIP_MODULE3_ORCHESTRATION=yes DEMO_FORCE_ROLE=\"\$target_role\" bash \"\$remote_dir/modules/module3.sh\" || rc=\$?; else printf '%s\n' \"\$sudo_pw\" | sudo -S -p '' env DEMO_SKIP_MODULE3_ORCHESTRATION=yes DEMO_FORCE_ROLE=\"\$target_role\" bash \"\$remote_dir/modules/module3.sh\" || rc=\$?; fi; if [ \"\$(id -u)\" -eq 0 ]; then rm -rf \"\$remote_dir\"; elif sudo -n true >/dev/null 2>&1; then sudo -n rm -rf \"\$remote_dir\"; else printf '%s\n' \"\$sudo_pw\" | sudo -S -p '' rm -rf \"\$remote_dir\"; fi; exit \$rc"

  log_ok "Starting remote Module 3: $target_role"
  tar -C "$PROJECT_DIR" -czf - VERSION lib modules config 2>/dev/null | \
    SSHPASS="$REMOTE_PASSWORD" sshpass -e ssh \
      -p "$REMOTE_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o IdentitiesOnly=yes \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o ConnectTimeout=10 \
      "$REMOTE_USER@$REMOTE_HOST" "$remote_cmd"
  log_ok "Remote Module 3 finished: $target_role"
}

run_remote_module3_role() {
  local target_role="$1"
  wait_for_remote_ssh "$target_role" || return 1
  stream_remote_module3_role "$target_role"
}

run_remote_module3_role_optional() {
  local target_role="$1"
  if ! wait_for_remote_ssh "$target_role" 2 2 yes; then
    log_warn "Skipping remote Module 3 for $target_role: no root-capable SSH from ISP"
    return 0
  fi
  stream_remote_module3_role "$target_role"
}

fetch_hq_srv_certs_to_isp() {
  if ! wait_for_remote_ssh "HQ-SRV" 2 2 yes; then
    log_warn "Cannot fetch HTTPS cert archive from HQ-SRV: SSH unavailable"
    return 0
  fi
  install_packages sshpass
  SSHPASS="$REMOTE_PASSWORD" sshpass -e scp \
    -P "$REMOTE_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "$REMOTE_USER@$REMOTE_HOST:$CA_DIR/out/nginx-web-docker-certs.tar.gz" \
    /tmp/nginx-web-docker-certs.tar.gz >/dev/null 2>&1 || \
      log_warn "Cert archive was not copied from HQ-SRV. ISP nginx HTTPS may be skipped."
}

run_with_failure_capture() {
  local description="$1"; shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log_error "$description"
  fi
  return "$rc"
}

run_module3_role_actions() {
  local role="$1"
  case "$role" in
  BR-SRV)
    run_if_needed "Module3 task1 import users" "[ -x /opt/import_users_module3.sh ]" setup_import_users_br_srv
    run_if_needed "Module3 rsyslog client" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-demo-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    run_if_needed "Module3 node_exporter BR-SRV" "systemctl is-active --quiet prometheus-node-exporter 2>/dev/null" setup_node_exporter
    run_if_needed "Module3 Ansible inventory task8" "[ -f /etc/ansible/PC-INFO/hq-srv.yml ] || [ -f /etc/ansible/PC-INFO/hq-cli.yml ]" setup_ansible_task8_br_srv
    ;;
  HQ-CLI)
    run_if_needed "Module3 domain user login PAM" "grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session 2>/dev/null" setup_hq_cli_domain_login
    run_if_needed "Module3 CA trust" "[ -f /usr/local/share/ca-certificates/demo-ca.crt ]" setup_ca_trust_hq_cli
    run_if_needed "Module3 CUPS client default printer" "lpstat -d 2>/dev/null | grep -q 'CUPS-PDF'" setup_cups_hq_cli
    run_if_needed "Module3 backup storage node" "id backupsvc >/dev/null 2>&1 && [ -d /backup/irpo/borg ]" setup_borg_storage_hq_cli
    ;;
  HQ-SRV)
    run_if_needed "Module3 local CA and web/docker certs" "[ -f '$CA_DIR/certs/ca.crt' ] && [ -f '$CA_DIR/certs/web.$DOMAIN_LOWER.crt' ]" setup_ca_hq_srv
    run_if_needed "Module3 CUPS PDF server" "systemctl is-active --quiet cups 2>/dev/null" setup_cups_hq_srv
    run_if_needed "Module3 rsyslog server and logrotate" "[ -f /etc/rsyslog.d/10-demo-remote-server.conf ] && [ -f /etc/logrotate.d/demo-remote-opt ]" setup_rsyslog_server_hq_srv
    run_if_needed "Module3 monitoring dashboard" "[ -f /var/www/mon/index.php ]" setup_monitoring_hq_srv
    run_if_needed "Module3 monitoring DNS mon.$DOMAIN_LOWER" "grep -q '^mon[[:space:]]\+IN[[:space:]]\+A' /etc/bind/zones/db.$DOMAIN_LOWER 2>/dev/null" setup_monitoring_dns_hq_srv
    run_if_needed "Module3 fail2ban ssh" "systemctl is-active --quiet fail2ban 2>/dev/null && grep -q '^port = $FAIL2BAN_SSH_PORT' /etc/fail2ban/jail.local 2>/dev/null" setup_fail2ban_hq_srv
    run_if_needed "Module3 backup scripts" "[ -x /usr/local/sbin/irpo-backup-etc.sh ] && [ -x /usr/local/sbin/irpo-backup-webdb.sh ]" setup_borg_hq_srv
    ;;
  HQ-RTR)
    run_if_needed "Module3 encrypted GRE with IPsec HQ-RTR" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null" "setup_ipsec_transport_gre '$HQ_RTR_WAN_IP' 'hq-rtr.$DOMAIN_LOWER' '$BR_RTR_WAN_IP' 'br-rtr.$DOMAIN_LOWER'"
    run_if_needed "Module3 firewall HQ-RTR" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST=\"$HQ_SRV_IP\"' /etc/start_iptables.sh 2>/dev/null" "setup_firewall_router '$HQ_SRV_IP'"
    run_if_needed "Module3 rsyslog client HQ-RTR" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-demo-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    ;;
  BR-RTR)
    run_if_needed "Module3 encrypted GRE with IPsec BR-RTR" "grep -q '^conn gre-encrypt' /etc/ipsec.conf 2>/dev/null" "setup_ipsec_transport_gre '$BR_RTR_WAN_IP' 'br-rtr.$DOMAIN_LOWER' '$HQ_RTR_WAN_IP' 'hq-rtr.$DOMAIN_LOWER'"
    run_if_needed "Module3 firewall BR-RTR" "[ -x /etc/start_iptables.sh ] && grep -q 'DEST=\"$BR_SRV_IP\"' /etc/start_iptables.sh 2>/dev/null" "setup_firewall_router '$BR_SRV_IP'"
    run_if_needed "Module3 rsyslog client BR-RTR" "grep -q '@$HQ_SRV_IP:514' /etc/rsyslog.d/90-demo-remote-forward.conf 2>/dev/null" setup_rsyslog_client
    ;;
  ISP)
    run_if_needed "Module3 nginx HTTPS proxy" "[ -f /etc/nginx/sites-enabled/demo-https-proxy ]" setup_nginx_https_isp
    ;;
  *)
    log_skip "No Module 3 actions for role: ${role:-unknown}"
    ;;
  esac
}

orchestrate_module3_from_isp() {
  local failures=0 role
  install_packages sshpass curl openssh-client

  # First prepare remote nodes. HQ-SRV goes first because it generates CA/certs and monitoring DNS.
  for role in $MODULE3_REMOTE_ROLES; do
    run_with_failure_capture "Module 3 role failed: $role" run_remote_module3_role_optional "$role" || failures=$((failures + 1))
    if [ "$role" = "HQ-SRV" ]; then
      fetch_hq_srv_certs_to_isp || true
    fi
  done

  # ISP is executed after remote nodes so nginx HTTPS can use the cert archive generated on HQ-SRV.
  run_with_failure_capture "Module 3 role failed: ISP" run_module3_role_actions "ISP" || failures=$((failures + 1))

  if [ "$failures" -gt 0 ]; then
    log_error "Module 3 ISP orchestration completed with $failures failure(s)"
    return 1
  fi
  log_ok "Module 3 ISP orchestration completed successfully"
}

if module3_orchestration_enabled; then
  orchestrate_module3_from_isp
else
  run_module3_role_actions "${ROLE:-unknown}"
fi

log_ok "Module 3 completed for role: ${ROLE:-unknown}"
