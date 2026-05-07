#!/usr/bin/env bash

validate_role() {
  case "$1" in
    ISP|HQ-RTR|BR-RTR|HQ-SRV|BR-SRV|HQ-CLI|HQ-SW) return 0 ;;
    *) log_error "Unsupported role: $1"; return 1 ;;
  esac
}

validate_interface_exists() {
  local iface="$1"
  [ -z "$iface" ] && return 0
  if ip link show "$iface" >/dev/null 2>&1; then
    return 0
  fi
  log_warn "Interface not found now: $iface"
  return 0
}

validate_ipv4_cidr() {
  local value="$1"
  if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || [ "$value" = "dhcp" ] || [ -z "$value" ]; then
    return 0
  fi
  log_warn "Value does not look like IPv4/CIDR or dhcp: $value"
}
