if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/bin/bash
# Runtime guard: routers/client SSH=22, servers SSH=2026.

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"
mkdir -p /etc/demo-autoconfig "$(dirname "$LOG_FILE")" 2>/dev/null || true

log_ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }

[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

set_kv() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
}

set_kv SSH_SERVER_PORT 2026
set_kv SSH_ROUTER_PORT 22
set_kv SSH_CLI_PORT 22
set_kv HQ_CLI_ANSIBLE_PORT 22

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"

case "$ROLE" in
  HQ-RTR|hq-rtr|BR-RTR|br-rtr|hqr|brr)
    if [ -f /etc/ssh/sshd_config ]; then
      if grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
        sed -i 's/^[#[:space:]]*Port[[:space:]].*/Port 22/' /etc/ssh/sshd_config
      else
        echo 'Port 22' >> /etc/ssh/sshd_config
      fi
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    fi
    ;;
esac

log_ok "SSH ports fixed: servers=2026 routers=22 client=22"
