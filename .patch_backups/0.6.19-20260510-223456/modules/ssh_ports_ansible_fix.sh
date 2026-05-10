if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/bin/bash
# ssh_ports_ansible_fix.sh
# Version: 0.6.16-ssh-ports-ansible-fix
# servers=2026, routers=22, client=22

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"
mkdir -p /etc/demo-autoconfig "$(dirname "$LOG_FILE")" 2>/dev/null || true
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"
DOMAIN="${DOMAIN:-au-team.irpo}"

HQ_SRV_IP="${HQ_SRV_IP:-192.168.100.2}"
HQ_CLI_IP="${HQ_CLI_IP:-192.168.200.2}"
HQ_RTR_HQ_IP="${HQ_RTR_HQ_IP:-192.168.100.1}"
BR_RTR_LAN_IP="${BR_RTR_LAN_IP:-192.168.255.1}"
BR_SRV_IP="${BR_SRV_IP:-192.168.255.2}"

SSH_SERVER_USER="${SSH_SERVER_USER:-sshuser}"
SSH_SERVER_PASSWORD="${SSH_SERVER_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}"
SSH_ROUTER_USER="${SSH_ROUTER_USER:-net_admin}"
SSH_ROUTER_PASSWORD="${SSH_ROUTER_PASSWORD:-${SSH_PASSWORD:-P@ssw0rd}}"
HQ_CLI_ANSIBLE_USER="${HQ_CLI_ANSIBLE_USER:-user}"
HQ_CLI_ANSIBLE_PASSWORD="${HQ_CLI_ANSIBLE_PASSWORD:-root}"

log_ok(){ echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }
log_warn(){ echo "$(date '+%F %T') [WARN] $*" | tee -a "$LOG_FILE"; }
log_fail(){ echo "$(date '+%F %T') [FAIL] $*" | tee -a "$LOG_FILE"; }

backup_file(){
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p /etc/demo-autoconfig/backups
  cp -a "$f" "/etc/demo-autoconfig/backups/$(echo "$f" | sed 's#/#_#g').$(date +%Y%m%d-%H%M%S).bak"
}

set_config_kv(){
  local key="$1" value="$2"
  [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
  backup_file "$CONFIG_FILE"
  if grep -q "^${key}=" "$CONFIG_FILE"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
}

fix_config_ports(){
  set_config_kv SSH_SERVER_PORT 2026
  set_config_kv SSH_ROUTER_PORT 22
  set_config_kv SSH_CLI_PORT 22
  set_config_kv HQ_CLI_ANSIBLE_PORT 22
  set_config_kv SSH_ROUTER_USER net_admin
  log_ok "config.env SSH ports fixed: servers=2026, routers=22, client=22"
}

fix_router_sshd_if_router(){
  case "$ROLE" in
    HQ-RTR|hq-rtr|BR-RTR|br-rtr|hqr|brr)
      if [ ! -f /etc/ssh/sshd_config ]; then
        log_fail "/etc/ssh/sshd_config not found"
        return 1
      fi
      backup_file /etc/ssh/sshd_config
      grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config && \
        sed -i 's/^[#[:space:]]*Port[[:space:]].*/Port 22/' /etc/ssh/sshd_config || echo 'Port 22' >> /etc/ssh/sshd_config
      grep -qE '^[#[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config && \
        sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
      grep -qE '^[#[:space:]]*AllowUsers' /etc/ssh/sshd_config && \
        sed -i 's/^[#[:space:]]*AllowUsers.*/AllowUsers net_admin/' /etc/ssh/sshd_config || echo 'AllowUsers net_admin' >> /etc/ssh/sshd_config
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
      log_ok "router ssh fixed: net_admin on port 22"
      ;;
    *) log_ok "router sshd fix skipped: ROLE=$ROLE" ;;
  esac
}

write_ansible_inventory_if_brsrv(){
  case "$ROLE" in
    BR-SRV|br-srv|br-srv.au-team.irpo) ;;
    *) log_ok "Ansible inventory rewrite skipped: ROLE=$ROLE"; return 0 ;;
  esac
  mkdir -p /etc/ansible
  backup_file /etc/ansible/hosts
  cat > /etc/ansible/hosts <<ANSIBLEEOF
[servers]
hq-srv ansible_host=${HQ_SRV_IP} ansible_port=2026 ansible_user=${SSH_SERVER_USER} ansible_password=${SSH_SERVER_PASSWORD}
br-srv ansible_host=${BR_SRV_IP} ansible_port=2026 ansible_user=${SSH_SERVER_USER} ansible_password=${SSH_SERVER_PASSWORD}

[clients]
hq-cli ansible_host=${HQ_CLI_IP} ansible_port=22 ansible_user=${HQ_CLI_ANSIBLE_USER} ansible_password=${HQ_CLI_ANSIBLE_PASSWORD}

[routers]
hq-rtr ansible_host=${HQ_RTR_HQ_IP} ansible_port=22 ansible_user=${SSH_ROUTER_USER} ansible_password=${SSH_ROUTER_PASSWORD}
br-rtr ansible_host=${BR_RTR_LAN_IP} ansible_port=22 ansible_user=${SSH_ROUTER_USER} ansible_password=${SSH_ROUTER_PASSWORD}

[all_hosts:children]
servers
clients
routers
ANSIBLEEOF
  cat > /etc/ansible/ansible.cfg <<'ANSIBLECFG'
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
ANSIBLECFG
  log_ok "Ansible inventory fixed: servers=2026, client/routers=22"
}

main(){
  log_ok "Starting SSH ports + Ansible fix 0.6.16"
  fix_config_ports
  fix_router_sshd_if_router
  write_ansible_inventory_if_brsrv
  echo "===== SSH PORTS FIX SUMMARY ====="
  echo "ROLE=$ROLE"
  echo "servers: 2026"
  echo "routers: 22"
  echo "client: 22"
  [ -f "$CONFIG_FILE" ] && grep -E '^(SSH_SERVER_PORT|SSH_ROUTER_PORT|SSH_CLI_PORT|HQ_CLI_ANSIBLE_PORT)=' "$CONFIG_FILE"
  log_ok "SSH ports + Ansible fix 0.6.16 finished"
}
main "$@"
