if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/bin/bash
# ansible_brsrv_prep.sh
# Version 0.6.15-brsrv-ansible-prep
# Must run on BR-SRV before Ansible configuration.

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"

log_ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "$(date '+%F %T') [WARN] $*" | tee -a "$LOG_FILE"; }
log_fail() { echo "$(date '+%F %T') [FAIL] $*" | tee -a "$LOG_FILE"; }

case "$ROLE" in
  BR-SRV|br-srv|br-srv.au-team.irpo)
    ;;
  *)
    log_warn "Ansible BR-SRV prep skipped: current ROLE=$ROLE"
    exit 0
    ;;
esac

DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y ansible sshpass openssh-client >/dev/null 2>&1

if command -v ansible >/dev/null 2>&1 && command -v sshpass >/dev/null 2>&1; then
  log_ok "ansible and sshpass installed"
else
  log_fail "ansible or sshpass install failed"
  exit 1
fi

mkdir -p /etc/ansible
chmod 755 /etc/ansible
log_ok "/etc/ansible prepared"

# Start ssh-agent if needed.
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  eval "$(ssh-agent -s)" >/dev/null 2>&1
  log_ok "ssh-agent started"
fi

# Show existing keys for log.
ssh-add -l >> "$LOG_FILE" 2>&1 || log_warn "ssh-agent has no loaded keys yet"

# Clear old loaded keys.
ssh-add -D >/dev/null 2>&1
log_ok "ssh-agent keys cleared"

# Ensure root SSH key exists.
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ ! -f /root/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa >/dev/null 2>&1
  log_ok "generated /root/.ssh/id_rsa"
fi

chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub 2>/dev/null || true

ssh-add /root/.ssh/id_rsa >/dev/null 2>&1
if ssh-add -l >/dev/null 2>&1; then
  log_ok "/root/.ssh/id_rsa loaded into ssh-agent"
else
  log_warn "could not load /root/.ssh/id_rsa into ssh-agent"
fi

log_ok "BR-SRV Ansible preparation finished"
