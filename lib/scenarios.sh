#!/usr/bin/env bash

cidr_ip() {
  printf '%s' "${1%%/*}"
}

ask_role_common() {
  local default_hostname="$1"
  prompt_default HOSTNAME "Hostname" "$default_hostname"
  prompt_default DOMAIN "Domain" "au-team.irpo"
  prompt_default DNS_SERVERS "DNS servers separated by spaces" "8.8.8.8 192.168.100.2"
  prompt_default INTERNET_TEST_IP "Internet test IP" "8.8.8.8"
}

set_module1_defaults() {
  ISO_PATH=""
  ISO_MOUNTPOINT="/mnt/additional"
  LOCK_RESOLV_CONF="no"
  MGMT_IFACE=""
  HOSTS_ENTRIES=""
  NEIGHBOR_IPS=""
  IP_FORWARD="no"
  NAT_ENABLE="no"
  NAT_OUT_IFACE=""
  NAT_LAN_CIDRS=""
  STATIC_ROUTES=""
  GRE_ENABLE="no"
  GRE_NAME="gre30"
  GRE_LOCAL_IP=""
  GRE_REMOTE_IP=""
  GRE_TUNNEL_LOCAL_CIDR=""
  GRE_TUNNEL_REMOTE_CIDR=""
  GRE_TTL="225"
  OSPF_ENABLE="no"
  OSPF_ROUTER_ID=""
  OSPF_NETWORKS=""
  DHCP_ENABLE="no"
  DHCP_IFACE=""
  DHCP_SUBNET=""
  DHCP_RANGE_START=""
  DHCP_RANGE_END=""
  DHCP_OPTION_ROUTERS=""
  DHCP_OPTION_DNS=""
  DHCP_DOMAIN="$DOMAIN"
  BIND_ENABLE="no"
  BIND_ZONES=""
  SSH_HARDENING="yes"
  SSH_PORT="22"
  SSH_PERMIT_ROOT_LOGIN="prohibit-password"
  SSH_PASSWORD_AUTHENTICATION="yes"
}

save_scenario_config() {
  backup_file "$CONFIG_FILE"
  write_kv_config "$CONFIG_FILE" \
    ROLE "$ROLE" HOSTNAME "$HOSTNAME" DOMAIN "$DOMAIN" \
    ISO_PATH "" ISO_MOUNTPOINT "/mnt/additional" LOCK_RESOLV_CONF "no" \
    INTERFACES "$INTERFACES" WAN_IFACE "$WAN_IFACE" LAN_IFACE "$LAN_IFACE" MGMT_IFACE "" \
    IPV4_CONFIGS "$IPV4_CONFIGS" DEFAULT_GW "$DEFAULT_GW" DNS_SERVERS "$DNS_SERVERS" HOSTS_ENTRIES "$HOSTS_ENTRIES" \
    NEIGHBOR_IPS "$NEIGHBOR_IPS" INTERNET_TEST_IP "$INTERNET_TEST_IP" \
    ROUTER_ROLES "ISP HQ-RTR BR-RTR" IP_FORWARD "$IP_FORWARD" NAT_ENABLE "$NAT_ENABLE" NAT_OUT_IFACE "$NAT_OUT_IFACE" NAT_LAN_CIDRS "$NAT_LAN_CIDRS" STATIC_ROUTES "$STATIC_ROUTES" \
    GRE_ENABLE "$GRE_ENABLE" GRE_NAME "$GRE_NAME" GRE_LOCAL_IP "$GRE_LOCAL_IP" GRE_REMOTE_IP "$GRE_REMOTE_IP" GRE_TUNNEL_LOCAL_CIDR "$GRE_TUNNEL_LOCAL_CIDR" GRE_TUNNEL_REMOTE_CIDR "$GRE_TUNNEL_REMOTE_CIDR" GRE_TTL "$GRE_TTL" \
    OSPF_ENABLE "$OSPF_ENABLE" OSPF_ROUTER_ID "$OSPF_ROUTER_ID" OSPF_NETWORKS "$OSPF_NETWORKS" \
    DHCP_ENABLE "$DHCP_ENABLE" DHCP_IFACE "$DHCP_IFACE" DHCP_SUBNET "$DHCP_SUBNET" DHCP_RANGE_START "$DHCP_RANGE_START" DHCP_RANGE_END "$DHCP_RANGE_END" DHCP_OPTION_ROUTERS "$DHCP_OPTION_ROUTERS" DHCP_OPTION_DNS "$DHCP_OPTION_DNS" DHCP_DOMAIN "$DHCP_DOMAIN" \
    BIND_ENABLE "$BIND_ENABLE" BIND_ZONES "$BIND_ZONES" \
    SSH_HARDENING "$SSH_HARDENING" SSH_PORT "$SSH_PORT" SSH_PERMIT_ROOT_LOGIN "$SSH_PERMIT_ROOT_LOGIN" SSH_PASSWORD_AUTHENTICATION "$SSH_PASSWORD_AUTHENTICATION"
  log_ok "Scenario config saved: $CONFIG_FILE"
}

scenario_isp() {
  ROLE="ISP"
  ask_role_common "isp"
  set_module1_defaults
  prompt_default WAN_IFACE "Uplink/NAT interface" "ens33"
  prompt_default ISP_HQ_IFACE "Interface toward HQ-RTR" "ens36"
  prompt_default ISP_BR_IFACE "Interface toward BR-RTR" "ens37"
  prompt_default ISP_HQ_IP_CIDR "ISP IP toward HQ-RTR" "172.16.1.1/28"
  prompt_default ISP_BR_IP_CIDR "ISP IP toward BR-RTR" "172.16.2.1/28"
  prompt_default HQ_RTR_WAN_IP "HQ-RTR WAN IP for route checks" "172.16.1.2"
  prompt_default BR_RTR_WAN_IP "BR-RTR WAN IP for route checks" "172.16.2.2"
  prompt_default NAT_LAN_CIDRS "Networks to NAT" "192.168.100.0/28 192.168.200.0/27 192.168.255.0/28"

  INTERFACES="$WAN_IFACE $ISP_HQ_IFACE $ISP_BR_IFACE"
  LAN_IFACE=""
  IPV4_CONFIGS="$WAN_IFACE:dhcp $ISP_HQ_IFACE:$ISP_HQ_IP_CIDR $ISP_BR_IFACE:$ISP_BR_IP_CIDR"
  DEFAULT_GW=""
  HOSTS_ENTRIES="$(cidr_ip "$ISP_HQ_IP_CIDR") docker.$DOMAIN docker;$(cidr_ip "$ISP_BR_IP_CIDR") web.$DOMAIN web;$HQ_RTR_WAN_IP hq-rtr.$DOMAIN hq-rtr;$BR_RTR_WAN_IP br-rtr.$DOMAIN br-rtr"
  NEIGHBOR_IPS="$HQ_RTR_WAN_IP $BR_RTR_WAN_IP"
  IP_FORWARD="yes"
  NAT_ENABLE="yes"
  NAT_OUT_IFACE="$WAN_IFACE"
  STATIC_ROUTES="192.168.100.0/28:$HQ_RTR_WAN_IP 192.168.200.0/27:$HQ_RTR_WAN_IP 192.168.255.0/28:$BR_RTR_WAN_IP"
  save_scenario_config
}

scenario_hq_rtr() {
  ROLE="HQ-RTR"
  ask_role_common "hq-rtr"
  set_module1_defaults
  prompt_default WAN_IFACE "WAN interface toward ISP" "ens33"
  prompt_default LAN_IFACE "Trunk/LAN interface" "ens36"
  prompt_default HQ_RTR_WAN_IP_CIDR "HQ-RTR WAN IP" "172.16.1.2/28"
  prompt_default ISP_HQ_IP "ISP gateway toward HQ" "172.16.1.1"
  prompt_default HQ_RTR_VLAN100_IP_CIDR "HQ-RTR VLAN100 IP" "192.168.100.1/28"
  prompt_default HQ_RTR_VLAN200_IP_CIDR "HQ-RTR VLAN200 IP" "192.168.200.1/27"
  prompt_default HQ_RTR_VLAN999_IP_CIDR "HQ-RTR VLAN999 IP" "192.168.250.1/29"
  prompt_default DHCP_ENABLE "Enable DHCP for HQ-CLI network" "yes"

  INTERFACES="$WAN_IFACE $LAN_IFACE $LAN_IFACE.100 $LAN_IFACE.200 $LAN_IFACE.999"
  IPV4_CONFIGS="$WAN_IFACE:$HQ_RTR_WAN_IP_CIDR $LAN_IFACE:manual $LAN_IFACE.100:$HQ_RTR_VLAN100_IP_CIDR $LAN_IFACE.200:$HQ_RTR_VLAN200_IP_CIDR $LAN_IFACE.999:$HQ_RTR_VLAN999_IP_CIDR"
  DEFAULT_GW="$ISP_HQ_IP"
  HOSTS_ENTRIES="$ISP_HQ_IP docker.$DOMAIN docker;192.168.100.2 hq-srv.$DOMAIN hq-srv"
  NEIGHBOR_IPS="$ISP_HQ_IP 192.168.100.2"
  IP_FORWARD="yes"
  NAT_ENABLE="yes"
  NAT_OUT_IFACE="$WAN_IFACE"
  NAT_LAN_CIDRS="192.168.100.0/28 192.168.200.0/27"
  STATIC_ROUTES=""
  if [ "$DHCP_ENABLE" = "yes" ]; then
    DHCP_IFACE="$LAN_IFACE.200"
    DHCP_SUBNET="192.168.200.0 netmask 255.255.255.224"
    DHCP_RANGE_START="192.168.200.2"
    DHCP_RANGE_END="192.168.200.30"
    DHCP_OPTION_ROUTERS="192.168.200.1"
    DHCP_OPTION_DNS="192.168.100.2"
  fi
  save_scenario_config
}

scenario_br_rtr() {
  ROLE="BR-RTR"
  ask_role_common "br-rtr"
  set_module1_defaults
  prompt_default WAN_IFACE "WAN interface toward ISP" "ens33"
  prompt_default LAN_IFACE "LAN interface" "ens36"
  prompt_default BR_RTR_WAN_IP_CIDR "BR-RTR WAN IP" "172.16.2.2/28"
  prompt_default ISP_BR_IP "ISP gateway toward BR" "172.16.2.1"
  prompt_default BR_RTR_LAN_IP_CIDR "BR LAN IP" "192.168.255.1/28"

  INTERFACES="$WAN_IFACE $LAN_IFACE"
  IPV4_CONFIGS="$WAN_IFACE:$BR_RTR_WAN_IP_CIDR $LAN_IFACE:$BR_RTR_LAN_IP_CIDR"
  DEFAULT_GW="$ISP_BR_IP"
  HOSTS_ENTRIES="$ISP_BR_IP web.$DOMAIN web;192.168.255.2 br-srv.$DOMAIN br-srv"
  NEIGHBOR_IPS="$ISP_BR_IP 192.168.255.2"
  IP_FORWARD="yes"
  NAT_ENABLE="yes"
  NAT_OUT_IFACE="$WAN_IFACE"
  NAT_LAN_CIDRS="192.168.255.0/28"
  STATIC_ROUTES=""
  save_scenario_config
}

scenario_hq_srv() {
  ROLE="HQ-SRV"
  ask_role_common "hq-srv"
  set_module1_defaults
  prompt_default LAN_IFACE "LAN interface" "ens33"
  prompt_default HQ_SRV_IP_CIDR "HQ-SRV IP" "192.168.100.2/28"
  prompt_default DEFAULT_GW "Default gateway" "192.168.100.1"
  prompt_default BIND_ENABLE "Install and enable bind9 base package" "yes"

  WAN_IFACE="$LAN_IFACE"
  INTERFACES="$LAN_IFACE"
  IPV4_CONFIGS="$LAN_IFACE:$HQ_SRV_IP_CIDR"
  HOSTS_ENTRIES="192.168.100.1 hq-rtr.$DOMAIN hq-rtr;192.168.200.2 hq-cli.$DOMAIN hq-cli;192.168.255.2 br-srv.$DOMAIN br-srv"
  NEIGHBOR_IPS="$DEFAULT_GW"
  NAT_OUT_IFACE=""
  DHCP_DOMAIN="$DOMAIN"
  BIND_ZONES="$DOMAIN"
  save_scenario_config
}

scenario_br_srv() {
  ROLE="BR-SRV"
  ask_role_common "br-srv"
  set_module1_defaults
  prompt_default LAN_IFACE "LAN interface" "ens33"
  prompt_default BR_SRV_IP_CIDR "BR-SRV IP" "192.168.255.2/28"
  prompt_default DEFAULT_GW "Default gateway" "192.168.255.1"

  WAN_IFACE="$LAN_IFACE"
  INTERFACES="$LAN_IFACE"
  IPV4_CONFIGS="$LAN_IFACE:$BR_SRV_IP_CIDR"
  HOSTS_ENTRIES="192.168.255.1 br-rtr.$DOMAIN br-rtr;192.168.100.2 hq-srv.$DOMAIN hq-srv"
  NEIGHBOR_IPS="$DEFAULT_GW"
  NAT_OUT_IFACE=""
  save_scenario_config
}

scenario_hq_cli() {
  ROLE="HQ-CLI"
  ask_role_common "hq-cli"
  set_module1_defaults
  prompt_default LAN_IFACE "LAN interface" "ens33"
  prompt_default IPV4_MODE "IPv4 mode: dhcp or static" "dhcp"
  if [ "$IPV4_MODE" = "static" ]; then
    prompt_default HQ_CLI_IP_CIDR "HQ-CLI IP" "192.168.200.2/27"
    prompt_default DEFAULT_GW "Default gateway" "192.168.200.1"
    IPV4_CONFIGS="$LAN_IFACE:$HQ_CLI_IP_CIDR"
  else
    DEFAULT_GW=""
    IPV4_CONFIGS="$LAN_IFACE:dhcp"
  fi

  WAN_IFACE="$LAN_IFACE"
  INTERFACES="$LAN_IFACE"
  HOSTS_ENTRIES="192.168.200.1 hq-rtr.$DOMAIN hq-rtr;192.168.100.2 hq-srv.$DOMAIN hq-srv"
  NEIGHBOR_IPS="${DEFAULT_GW:-192.168.200.1}"
  NAT_OUT_IFACE=""
  SSH_HARDENING="no"
  save_scenario_config
}
