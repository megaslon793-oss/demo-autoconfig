#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs
load_config

log_ok "Module 2 scaffold loaded for role: ${ROLE}"
log_warn "TODO: Samba AD DC, Kerberos, users/groups, CSV import, domain join, RAID0, NFS, Chrony, Ansible, Docker from ISO tar images, Apache/MariaDB, nginx reverse proxy, basic auth, Yandex Browser deb."
log_warn "Safe policy active: no Samba config deletion, RAID recreation, disk formatting, Docker cleanup, or internet image pulls will run without explicit implementation and confirmation."

case "$ROLE" in
  BR-SRV)
    log_skip "Samba AD DC and Docker application blocks are placeholders."
    ;;
  HQ-SRV)
    log_skip "RAID0, NFS, Apache and MariaDB blocks are placeholders."
    ;;
  HQ-CLI)
    log_skip "Domain join, NFS client and browser installation blocks are placeholders."
    ;;
  ISP)
    log_skip "nginx reverse proxy and basic auth blocks are placeholders."
    ;;
  *)
    log_skip "No Module 2 placeholder actions for role: $ROLE."
    ;;
esac
