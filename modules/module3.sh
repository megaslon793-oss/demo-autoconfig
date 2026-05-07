#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

log_ok "Module 3 scaffold loaded for role: ${ROLE}"
log_warn "TODO: user import, local CA, certificates, HTTPS, secured tunnel, firewall, CUPS, rsyslog, logrotate, monitoring, Ansible inventory, fail2ban, backups."
log_warn "Safe policy active: security/firewall changes are placeholders until exact task parameters are added to config.env."

case "$ROLE" in
  HQ-RTR|BR-RTR)
    log_skip "Router firewall block is a placeholder."
    ;;
  HQ-SRV)
    log_skip "CUPS, rsyslog, monitoring and backup blocks are placeholders."
    ;;
  BR-SRV)
    log_skip "CA, certificates, HTTPS and Ansible inventory blocks are placeholders."
    ;;
  *)
    log_skip "No Module 3 placeholder actions for role: $ROLE."
    ;;
esac
