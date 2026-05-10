#!/bin/bash
# demo-autoconfig diagnostics
# Version: 0.6.9-diagnostics-readable
# Purpose: show what is ready and what is broken by modules/roles.

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_DIR="${LOG_DIR:-/var/log}"
REPORT_FILE="${REPORT_FILE:-$LOG_DIR/demo-autoconfig-diagnostics-$(date +%Y%m%d-%H%M%S).log}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

mkdir -p "$LOG_DIR" 2>/dev/null || true

if [ -f "$CONFIG_FILE" ]; then
  . "$CONFIG_FILE"
fi

ROLE="${ROLE:-$(hostname -s 2>/dev/null | tr '[:lower:]' '[:upper:]')}"
DOMAIN="${DOMAIN:-au-team.irpo}"

ISP_HQ_IP="${ISP_HQ_IP:-172.16.1.1}"
ISP_BR_IP="${ISP_BR_IP:-172.16.2.1}"
HQ_RTR_WAN_IP="${HQ_RTR_WAN_IP:-172.16.1.2}"
BR_RTR_WAN_IP="${BR_RTR_WAN_IP:-172.16.2.2}"
HQ_RTR_LAN_IP="${HQ_RTR_LAN_IP:-192.168.100.1}"
HQ_RTR_CLI_IP="${HQ_RTR_CLI_IP:-192.168.200.1}"
BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"
GRE_HQ_IP="${GRE_HQ_IP:-10.0.0.1}"
GRE_BR_IP="${GRE_BR_IP:-10.0.0.2}"

SSH_SERVER_PORT="${SSH_SERVER_PORT:-2026}"
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"
SSH_SERVER_USER="${SSH_SERVER_USER:-sshuser}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_CLI_USER="${SSH_CLI_USER:-sshuser}"

DIAG_ORCHESTRATE_FROM_ISP="${DIAG_ORCHESTRATE_FROM_ISP:-yes}"

say() {
  echo -e "$*" | tee -a "$REPORT_FILE"
}

line() {
  say "----------------------------------------------------------------"
}

section() {
  say ""
  line
  say "### $1"
  line
}

record_ok() {
  OK_COUNT=$((OK_COUNT+1))
  say "[OK]   $*"
}

record_warn() {
  WARN_COUNT=$((WARN_COUNT+1))
  say "[WARN] $*"
}

record_fail() {
  FAIL_COUNT=$((FAIL_COUNT+1))
  say "[FAIL] $*"
}

record_skip() {
  SKIP_COUNT=$((SKIP_COUNT+1))
  say "[SKIP] $*"
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_quiet() {
  bash -c "$*" >/tmp/demo_diag_cmd.out 2>/tmp/demo_diag_cmd.err
  return $?
}

check_cmd() {
  local title="$1"
  local command="$2"
  if run_quiet "$command"; then
    record_ok "$title"
    return 0
  else
    record_fail "$title"
    say "       command: $command"
    say "       stderr: $(head -n 2 /tmp/demo_diag_cmd.err | tr '\n' ' ')"
    return 1
  fi
}

check_cmd_warn() {
  local title="$1"
  local command="$2"
  if run_quiet "$command"; then
    record_ok "$title"
    return 0
  else
    record_warn "$title"
    say "       command: $command"
    say "       stderr: $(head -n 2 /tmp/demo_diag_cmd.err | tr '\n' ' ')"
    return 1
  fi
}

check_service() {
  local svc="$1"
  if systemctl status "$svc" >/dev/null 2>&1 || systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc"; then
      record_ok "service active: $svc"
    else
      record_fail "service not active: $svc"
      systemctl status "$svc" --no-pager -l 2>/dev/null | sed -n '1,8p' | tee -a "$REPORT_FILE"
    fi
  else
    record_fail "service not found: $svc"
  fi
}

check_pkg_any() {
  local title="$1"
  shift
  local found=0
  for pkg in "$@"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      found=1
      record_ok "$title package installed: $pkg"
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    record_fail "$title package missing: $*"
  fi
}

check_ping() {
  local title="$1"
  local target="$2"
  ping -c 2 -W 2 "$target" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    record_ok "$title ping $target"
  else
    record_fail "$title ping $target"
  fi
}

check_tcp() {
  local title="$1"
  local host="$2"
  local port="$3"
  if cmd_exists nc; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1
  fi
  if [ $? -eq 0 ]; then
    record_ok "$title tcp $host:$port"
  else
    record_fail "$title tcp $host:$port"
  fi
}

basic_diagnostics() {
  section "BASIC / COMMON"

  say "Report: $REPORT_FILE"
  say "Role: ${ROLE}"
  say "Hostname: $(hostname -f 2>/dev/null || hostname)"
  say "Config: $CONFIG_FILE"

  check_cmd_warn "hostname has FQDN or short name" "hostname -f || hostname"
  check_cmd_warn "interfaces visible" "ip -br a"
  check_cmd_warn "routes visible" "ip route"
  check_cmd_warn "resolv.conf visible" "cat /etc/resolv.conf"

  if ip route | grep -q '^default '; then
    record_ok "default route exists"
  else
    record_warn "default route missing"
  fi

  ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    record_ok "internet by IP: 8.8.8.8"
  else
    record_warn "internet by IP failed: 8.8.8.8"
  fi

  if cmd_exists nslookup; then
    nslookup google.com >/dev/null 2>&1 && record_ok "external DNS: google.com" || record_warn "external DNS failed: google.com"
    nslookup "hq-srv.$DOMAIN" "$HQ_SRV_IP" >/dev/null 2>&1 && record_ok "internal DNS via HQ-SRV" || record_warn "internal DNS via HQ-SRV failed"
  else
    record_warn "nslookup not installed"
  fi
}

module1_diagnostics() {
  section "MODULE 1 / NETWORK"

  case "$ROLE" in
    ISP|isp)
      check_cmd "IPv4 forwarding enabled" "test \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1"
      check_cmd_warn "iptables available" "command -v iptables || test -x /usr/sbin/iptables"
      check_cmd "NAT MASQUERADE exists" "/usr/sbin/iptables -t nat -S 2>/dev/null | grep -q MASQUERADE"
      check_cmd_warn "FORWARD policy/rules visible" "/usr/sbin/iptables -L FORWARD -n -v"
      check_ping "HQ-RTR WAN" "$HQ_RTR_WAN_IP"
      check_ping "BR-RTR WAN" "$BR_RTR_WAN_IP"
      ;;
    HQ-RTR|hq-rtr|HQR|hqr)
      check_cmd "IPv4 forwarding enabled" "test \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1"
      check_cmd_warn "GRE interface exists" "ip a show gre30"
      check_ping "GRE peer BR-RTR" "$GRE_BR_IP"
      check_pkg_any "FRR" frr
      check_service frr
      check_cmd_warn "OSPF neighbor visible" "vtysh -c 'show ip ospf neighbor'"
      check_cmd_warn "OSPF routes visible" "vtysh -c 'show ip route ospf'"
      check_service isc-dhcp-server
      check_cmd_warn "DHCP config syntax" "dhcpd -t -cf /etc/dhcp/dhcpd.conf"
      check_cmd_warn "DHCP interface set" "grep -E '^INTERFACESv4=' /etc/default/isc-dhcp-server"
      ;;
    BR-RTR|br-rtr|BRR|brr)
      check_cmd "IPv4 forwarding enabled" "test \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1"
      check_cmd_warn "GRE interface exists" "ip a show gre30"
      check_ping "GRE peer HQ-RTR" "$GRE_HQ_IP"
      check_pkg_any "FRR" frr
      check_service frr
      check_cmd_warn "OSPF neighbor visible" "vtysh -c 'show ip ospf neighbor'"
      check_cmd_warn "OSPF routes visible" "vtysh -c 'show ip route ospf'"
      ;;
    HQ-SRV|hq-srv)
      check_pkg_any "BIND9" bind9
      check_service bind9
      check_cmd_warn "BIND config check" "named-checkconf"
      if [ -f /etc/bind/zones/db.au-team.irpo ]; then
        check_cmd_warn "DNS zone check au-team.irpo" "named-checkzone au-team.irpo /etc/bind/zones/db.au-team.irpo"
      else
        record_fail "DNS zone missing: /etc/bind/zones/db.au-team.irpo"
      fi
      for name in hq-rtr br-rtr hq-srv hq-cli br-srv docker web; do
        nslookup "$name.$DOMAIN" 127.0.0.1 >/dev/null 2>&1 && record_ok "DNS A: $name.$DOMAIN" || record_fail "DNS A missing/broken: $name.$DOMAIN"
      done
      check_service ssh
      check_tcp "SSH server" "127.0.0.1" "$SSH_SERVER_PORT"
      ;;
    BR-SRV|br-srv)
      check_service ssh
      check_tcp "SSH server" "127.0.0.1" "$SSH_SERVER_PORT"
      ;;
    HQ-CLI|hq-cli)
      check_cmd_warn "DHCP/client IP present" "ip -br a"
      check_ping "gateway HQ-RTR VLAN200" "$HQ_RTR_CLI_IP"
      nslookup "hq-srv.$DOMAIN" "$HQ_SRV_IP" >/dev/null 2>&1 && record_ok "DNS client query to HQ-SRV" || record_fail "DNS client query to HQ-SRV"
      ;;
    HQ-SW|hq-sw)
      check_pkg_any "Open vSwitch" openvswitch-switch
      check_service openvswitch-switch
      check_cmd_warn "OVS bridge config" "ovs-vsctl show"
      ;;
    *)
      record_warn "unknown role for Module 1 checks: $ROLE"
      ;;
  esac
}

module2_diagnostics() {
  section "MODULE 2 / SERVICES"

  case "$ROLE" in
    BR-SRV|br-srv)
      check_pkg_any "Samba" samba
      check_service samba-ad-dc
      check_cmd_warn "Samba domain info" "samba-tool domain info 127.0.0.1"
      local users_count
      users_count="$(samba-tool user list 2>/dev/null | wc -l | tr -d ' ')"
      say "Samba users count: ${users_count:-0}"
      if [ "${users_count:-0}" -ge 10 ]; then
        record_ok "Samba users count >= 10"
      else
        record_warn "Samba users count looks low: ${users_count:-0}"
      fi
      check_cmd_warn "Samba group hq exists" "samba-tool group list | grep -x hq"
      check_pkg_any "Docker" docker-ce docker.io docker
      if cmd_exists docker; then
        check_cmd_warn "Docker images visible" "docker images"
        check_cmd_warn "Docker containers visible" "docker ps"
        docker ps --format '{{.Names}}' | grep -qx 'tespapp' && record_ok "Docker app container: tespapp" || record_warn "Docker app container tespapp not running"
        docker ps --format '{{.Names}}' | grep -qx 'db' && record_ok "Docker db container: db" || record_warn "Docker db container db not running"
      fi
      check_pkg_any "Ansible" ansible
      check_cmd_warn "Ansible inventory exists" "test -f /etc/ansible/hosts"
      if cmd_exists ansible; then
        check_cmd_warn "Ansible ping all_hosts" "ansible all_hosts -m ping"
      fi
      ;;
    HQ-SRV|hq-srv)
      check_pkg_any "mdadm" mdadm
      check_cmd_warn "RAID status" "cat /proc/mdstat"
      grep -q '/raid' /proc/mounts && record_ok "/raid mounted" || record_fail "/raid not mounted"
      check_pkg_any "NFS server" nfs-kernel-server
      check_service nfs-kernel-server
      check_cmd_warn "NFS exports" "exportfs -v"
      check_pkg_any "Apache" apache2
      check_service apache2
      check_pkg_any "MariaDB" mariadb-server
      check_service mariadb
      check_cmd_warn "Web local HTTP" "curl -fsS --max-time 5 http://127.0.0.1 >/dev/null"
      ;;
    HQ-CLI|hq-cli)
      grep -q '/mnt/nfs' /proc/mounts && record_ok "/mnt/nfs mounted" || record_warn "/mnt/nfs not mounted"
      check_cmd_warn "realm list" "realm list"
      ;;
    ISP|isp)
      check_pkg_any "nginx" nginx
      check_service nginx
      check_cmd_warn "nginx config syntax" "nginx -t"
      check_cmd_warn "web proxy HTTP" "curl -I --max-time 5 http://web.$DOMAIN"
      check_cmd_warn "docker proxy HTTP" "curl -I --max-time 5 http://docker.$DOMAIN"
      ;;
    *)
      record_skip "No detailed Module 2 checks for role: $ROLE"
      ;;
  esac

  if cmd_exists chronyc; then
    check_cmd_warn "Chrony sources" "chronyc sources"
  else
    record_warn "chrony/chronyc not installed"
  fi
}

module3_diagnostics() {
  section "MODULE 3 / SECURITY + OPERATIONS"

  case "$ROLE" in
    ISP|isp)
      check_pkg_any "nginx" nginx
      check_service nginx
      check_cmd_warn "HTTPS web proxy" "curl -k -I --max-time 5 https://web.$DOMAIN"
      check_cmd_warn "HTTPS docker proxy" "curl -k -I --max-time 5 https://docker.$DOMAIN"
      ;;
    HQ-RTR|hq-rtr|BR-RTR|br-rtr)
      check_pkg_any "IPsec/strongSwan" strongswan strongswan-starter
      if cmd_exists ipsec; then
        check_cmd_warn "IPsec status" "ipsec statusall"
      else
        record_fail "ipsec command missing"
      fi
      if ip xfrm state 2>/dev/null | grep -q .; then
        record_ok "xfrm states exist"
      else
        record_fail "xfrm state is empty"
      fi
      check_cmd_warn "firewall filter table" "/usr/sbin/iptables -L -n -v"
      ;;
    HQ-SRV|hq-srv)
      check_pkg_any "CUPS" cups
      check_service cups
      check_cmd_warn "CUPS printers" "lpstat -p"
      check_pkg_any "rsyslog" rsyslog
      check_service rsyslog
      if find /opt -type f 2>/dev/null | grep -q .; then
        record_ok "rsyslog files exist in /opt"
      else
        record_warn "no log files found in /opt yet"
      fi
      check_pkg_any "fail2ban" fail2ban
      check_service fail2ban
      check_cmd_warn "fail2ban sshd jail" "fail2ban-client status sshd"
      check_cmd_warn "monitoring URL local" "curl -fsS --max-time 5 http://127.0.0.1 >/dev/null"
      ;;
    BR-SRV|br-srv)
      if [ -f /mnt/additional/Users.csv ]; then
        record_ok "Users.csv exists"
      else
        record_fail "Users.csv missing: /mnt/additional/Users.csv"
      fi
      local users_count
      users_count="$(samba-tool user list 2>/dev/null | wc -l | tr -d ' ')"
      say "Samba users count: ${users_count:-0}"
      if [ "${users_count:-0}" -ge 20 ]; then
        record_ok "Imported users count looks good"
      else
        record_fail "Imported users count too low: ${users_count:-0}"
      fi
      check_pkg_any "rsyslog" rsyslog
      check_service rsyslog
      ;;
    HQ-CLI|hq-cli)
      check_cmd_warn "default printer" "lpstat -d"
      check_cmd_warn "monitoring URL from client" "curl -fsS --max-time 5 http://mon.$DOMAIN >/dev/null"
      check_cmd_warn "HTTPS web from client" "curl -k -I --max-time 5 https://web.$DOMAIN"
      check_cmd_warn "HTTPS docker from client" "curl -k -I --max-time 5 https://docker.$DOMAIN"
      if [ -d /backup ]; then
        record_ok "/backup directory exists"
      else
        record_warn "/backup directory missing"
      fi
      ;;
    *)
      record_skip "No detailed Module 3 checks for role: $ROLE"
      ;;
  esac
}

remote_diag_command() {
  cat <<'REMOTE_EOF'
set +e
if [ -f /opt/demo-autoconfig/modules/diagnostics.sh ]; then
  sudo bash /opt/demo-autoconfig/modules/diagnostics.sh --local-only
elif [ -f /tmp/demo-autoconfig/modules/diagnostics.sh ]; then
  sudo bash /tmp/demo-autoconfig/modules/diagnostics.sh --local-only
else
  echo "[FAIL] diagnostics.sh not found on remote host"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "ip:"
  ip -br a
  echo "routes:"
  ip route
fi
REMOTE_EOF
}

run_remote() {
  local title="$1"
  local host="$2"
  local port="$3"
  local user="$4"

  section "REMOTE DIAGNOSTICS: $title ($user@$host:$port)"

  if ! cmd_exists ssh; then
    record_fail "ssh command missing on ISP"
    return 1
  fi

  ssh -o BatchMode=no \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=8 \
      -p "$port" "$user@$host" "$(remote_diag_command)" 2>&1 | tee -a "$REPORT_FILE"

  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    record_ok "remote diagnostics finished: $title"
  else
    record_fail "remote diagnostics failed: $title"
  fi
}

orchestrate_from_isp() {
  section "ISP ORCHESTRATED DIAGNOSTICS"

  say "This block checks other nodes over SSH. If SSH/passwords are not ready, local checks may still be OK."

  run_remote "HQ-RTR" "$HQ_RTR_WAN_IP" "$SSH_ROUTER_PORT" "$SSH_ROUTER_USER"
  run_remote "BR-RTR" "$BR_RTR_WAN_IP" "$SSH_ROUTER_PORT" "$SSH_ROUTER_USER"
  run_remote "HQ-SRV" "$HQ_SRV_IP" "$SSH_SERVER_PORT" "$SSH_SERVER_USER"
  run_remote "BR-SRV" "$BR_SRV_IP" "$SSH_SERVER_PORT" "$SSH_SERVER_USER"
  run_remote "HQ-CLI" "$HQ_CLI_IP" "22" "$SSH_CLI_USER"
}

summary() {
  section "SUMMARY"

  say "OK:   $OK_COUNT"
  say "WARN: $WARN_COUNT"
  say "FAIL: $FAIL_COUNT"
  say "SKIP: $SKIP_COUNT"
  say "Report saved to: $REPORT_FILE"

  if [ "$FAIL_COUNT" -eq 0 ]; then
    say "[RESULT] READY ENOUGH: no hard failures detected."
    exit 0
  else
    say "[RESULT] NOT READY: fix FAIL items first."
    exit 1
  fi
}

main() {
  : > "$REPORT_FILE"
  say "demo-autoconfig diagnostics started: $(date)"
  say "args: $*"

  local local_only="no"
  if [ "${1:-}" = "--local-only" ]; then
    local_only="yes"
  fi

  basic_diagnostics
  module1_diagnostics
  module2_diagnostics
  module3_diagnostics

  if [ "$local_only" != "yes" ] && [[ "$ROLE" =~ ^(ISP|isp)$ ]] && [ "$DIAG_ORCHESTRATE_FROM_ISP" = "yes" ]; then
    orchestrate_from_isp
  fi

  summary
}

main "$@"
