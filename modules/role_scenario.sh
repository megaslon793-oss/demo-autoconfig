#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
ensure_dirs

ROLE_SCENARIO="${ROLE_SCENARIO:-${1:-}}"

case "$ROLE_SCENARIO" in
  ISP) scenario_isp ;;
  HQ-RTR) scenario_hq_rtr ;;
  BR-RTR) scenario_br_rtr ;;
  *) log_error "Unknown role scenario: $ROLE_SCENARIO"; exit 1 ;;
esac

load_config
set_hostname_idempotent "$HOSTNAME"
configure_hosts
configure_resolv_conf

if confirm "Run Module 1 now?"; then
  bash "$PROJECT_DIR/modules/module1.sh"
else
  log_ok "Scenario prepared. Run Module 1 from menu when ready."
fi
