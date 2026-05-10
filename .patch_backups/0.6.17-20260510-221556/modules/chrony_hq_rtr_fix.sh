#!/bin/bash
# chrony_hq_rtr_fix.sh
# Safe helper for configuring chrony on HQ-RTR.
# Version: 0.6.12-hq-rtr-chrony-fix

set +e

CONFIG_FILE="${CONFIG_FILE:-/etc/demo-autoconfig/config.env}"
LOG_FILE="${LOG_FILE:-/var/log/demo-autoconfig.log}"

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

ROLE="${ROLE:-$(hostname -s 2>/dev/null)}"
NTP_SERVER_IP="${NTP_SERVER_IP:-172.16.1.1}"

log_ok() { echo "$(date '+%F %T') [OK] $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "$(date '+%F %T') [WARN] $*" | tee -a "$LOG_FILE"; }
log_fail() { echo "$(date '+%F %T') [FAIL] $*" | tee -a "$LOG_FILE"; }

configure_hq_rtr_chrony() {
  case "$ROLE" in
    HQ-RTR|hq-rtr|hqr|HQR|hq-rtr.au-team.irpo)
      ;;
    *)
      log_warn "chrony HQ-RTR fix skipped: current ROLE=$ROLE"
      return 0
      ;;
  esac

  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1

  if ! command -v chronyc >/dev/null 2>&1; then
    log_fail "chrony install failed on HQ-RTR"
    return 1
  fi

  if [ -f /etc/chrony/chrony.conf ]; then
    cp /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  cat > /etc/chrony/chrony.conf <<EOF
server ${NTP_SERVER_IP} iburst

driftfile /var/lib/chrony/chrony.drift
log tracking measurements statistics
logdir /var/log/chrony
rtcsync
makestep 1.0 3
EOF

  systemctl enable --now chrony >/dev/null 2>&1
  systemctl restart chrony >/dev/null 2>&1

  if systemctl is-active --quiet chrony; then
    log_ok "chrony configured on HQ-RTR, server=${NTP_SERVER_IP}"
    chronyc sources 2>/dev/null | tee -a "$LOG_FILE" || true
  else
    log_fail "chrony service is not active on HQ-RTR"
    systemctl status chrony --no-pager -l 2>/dev/null | sed -n '1,12p' | tee -a "$LOG_FILE"
    return 1
  fi
}

configure_hq_rtr_chrony
