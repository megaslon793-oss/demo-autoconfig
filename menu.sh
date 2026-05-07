#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR

# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

require_root
init_log

show_menu() {
  cat <<'MENU'

demo-autoconfig
1. Initial setup
2. Module 1
3. Module 2
4. Module 3
5. Diagnostics
6. Cleanup temporary files
0. Exit

Quick scenarios: ISP, HQ-RTR, BR-RTR
MENU
}

run_module() {
  local module="$1"
  if [ ! -x "$PROJECT_DIR/modules/$module" ]; then
    chmod +x "$PROJECT_DIR/modules/$module" 2>/dev/null || true
  fi
  bash "$PROJECT_DIR/modules/$module"
}

while true; do
  show_menu
  read -r -p "Select action: " choice
  case "$choice" in
    1) run_module initial_setup.sh ;;
    2) run_module module1.sh ;;
    3) run_module module2.sh ;;
    4) run_module module3.sh ;;
    5) run_module diagnostics.sh ;;
    6) cleanup_temporary_files ;;
    ISP|isp) export ROLE_SCENARIO="ISP"; run_module role_scenario.sh; unset ROLE_SCENARIO ;;
    HQ-RTR|hq-rtr) export ROLE_SCENARIO="HQ-RTR"; run_module role_scenario.sh; unset ROLE_SCENARIO ;;
    BR-RTR|br-rtr) export ROLE_SCENARIO="BR-RTR"; run_module role_scenario.sh; unset ROLE_SCENARIO ;;
    0) log_ok "Exit"; exit 0 ;;
    *) log_warn "Unknown option: $choice" ;;
  esac
done
