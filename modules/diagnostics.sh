#!/bin/bash
CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s)}"
DOMAIN="${DOMAIN:-au-team.irpo}"
HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"

ok=0; warn=0; fail=0
OK(){ echo "[OK]   $*"; ok=$((ok+1)); }
WARN(){ echo "[WARN] $*"; warn=$((warn+1)); }
FAIL(){ echo "[FAIL] $*"; fail=$((fail+1)); }

echo "===== DIAGNOSTICS role=$ROLE host=$(hostname -f 2>/dev/null || hostname) ====="

echo "--- DNS ---"
cat /etc/resolv.conf
nslookup hq-srv.$DOMAIN >/dev/null 2>&1 && OK "hq-srv resolves" || FAIL "hq-srv does not resolve"
nslookup br-srv.$DOMAIN >/dev/null 2>&1 && OK "br-srv resolves" || FAIL "br-srv does not resolve"
nslookup web.$DOMAIN >/dev/null 2>&1 && OK "web resolves" || FAIL "web does not resolve"
nslookup docker.$DOMAIN >/dev/null 2>&1 && OK "docker resolves" || FAIL "docker does not resolve"

echo "--- Network ---"
ip route | grep -q '^default' && OK "default route exists" || WARN "default route missing"
ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && OK "internet IP ping works" || WARN "internet IP ping failed"

case "$ROLE" in
  ISP|isp)
    systemctl is-active --quiet nginx && OK "nginx active" || FAIL "nginx inactive"
    curl -I --max-time 5 http://web.$DOMAIN 2>/dev/null | grep -Eq '401|200|30' && OK "HTTP web proxy answers" || FAIL "HTTP web proxy broken"
    curl --max-time 5 http://docker.$DOMAIN 2>/dev/null | grep -q . && OK "HTTP docker proxy answers GET" || FAIL "HTTP docker proxy broken"
    curl -k -I --max-time 5 https://web.$DOMAIN 2>/dev/null | grep -Eq '401|200|30' && OK "HTTPS web proxy answers" || WARN "HTTPS web proxy not ready"
    curl -k --max-time 5 https://docker.$DOMAIN 2>/dev/null | grep -q . && OK "HTTPS docker proxy answers GET" || WARN "HTTPS docker proxy not ready"
    ;;
  HQ-RTR|hq-rtr|BR-RTR|br-rtr)
    command -v ipsec >/dev/null 2>&1 && OK "ipsec command exists" || FAIL "ipsec command missing"
    systemctl is-active --quiet strongswan-starter && OK "strongswan-starter active" || WARN "strongswan-starter inactive/missing"
    ip xfrm state 2>/dev/null | grep -q . && OK "xfrm state exists" || FAIL "xfrm state empty"
    /usr/sbin/iptables -L -n >/dev/null 2>&1 && OK "iptables works" || FAIL "iptables missing/broken"
    ;;
  BR-SRV|br-srv)
    systemctl is-active --quiet samba-ad-dc && OK "samba-ad-dc active" || FAIL "samba-ad-dc inactive"
    count="$(samba-tool user list 2>/dev/null | wc -l)"
    echo "Samba users count: $count"
    [ "$count" -ge 20 ] && OK "users imported" || FAIL "users not imported enough"
    [ -f /mnt/additional/Users.csv ] && OK "Users.csv exists" || FAIL "Users.csv missing"
    ;;
  HQ-SRV|hq-srv)
    systemctl is-active --quiet bind9 || systemctl is-active --quiet named
    [ $? -eq 0 ] && OK "bind9/named active" || FAIL "bind9/named inactive"
    systemctl is-active --quiet cups && OK "cups active" || WARN "cups inactive"
    systemctl is-active --quiet fail2ban && OK "fail2ban active" || WARN "fail2ban inactive"
    ;;
  HQ-CLI|hq-cli)
    lpstat -d >/dev/null 2>&1 && OK "default printer configured" || WARN "default printer not configured"
    curl -I --max-time 5 http://web.$DOMAIN 2>/dev/null | grep -Eq '401|200|30' && OK "client sees web" || FAIL "client cannot see web"
    curl --max-time 5 http://docker.$DOMAIN 2>/dev/null | grep -q . && OK "client sees docker" || FAIL "client cannot see docker"
    ;;
esac

echo "===== SUMMARY OK=$ok WARN=$warn FAIL=$fail ====="
[ "$fail" -eq 0 ]
