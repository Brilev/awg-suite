#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORK_DIR="$(pwd)"
AWG0_CONF="$WORK_DIR/awg0.conf"
AWG1_CONF="$WORK_DIR/awg1.conf"

log() {
  echo "[awg-bootstrap] $*"
}

fail() {
  echo "[awg-bootstrap] ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "command not found: $1"
}

need_cmd uci
need_cmd awk
need_cmd sed
need_cmd grep

require_input() {
  if [ ! -f "$AWG0_CONF" ] && [ ! -f "$AWG1_CONF" ]; then
    fail "put awg0.conf and/or awg1.conf in the current directory: $WORK_DIR"
  fi
}

extract_conf_value() {
  section="$1"
  key="$2"
  file="$3"

  awk -F '=' -v want_section="$section" -v want_key="$key" '
    function trim(s) {
      sub(/^[ \t\r\n]+/, "", s)
      sub(/[ \t\r\n]+$/, "", s)
      return s
    }
    /^\[/ {
      current=trim($0)
      gsub(/^\[/, "", current)
      gsub(/\]$/, "", current)
      next
    }
    current == want_section {
      k=trim($1)
      v=substr($0, index($0, "=")+1)
      v=trim(v)
      if (k == want_key) {
        print v
        exit
      }
    }
  ' "$file"
}

split_endpoint_host() {
  echo "$1" | sed 's/:.*$//'
}

split_endpoint_port() {
  echo "$1" | sed 's/^.*://'
}

uci_set_if_present() {
  option="$1"
  value="$2"
  [ -n "$value" ] && uci set "$option=$value" || true
}

run_vendor_installer() {
  name="$1"
  path="$SCRIPT_DIR/vendor/$name"
  if [ -f "$path" ]; then
    log "running vendor/$name"
    sh "$path" || fail "vendor/$name failed"
  fi
}

configure_iface_from_conf() {
  iface="$1"
  file="$2"
  metric="$3"
  table="$4"

  [ -f "$file" ] || return 0

  private_key="$(extract_conf_value Interface PrivateKey "$file")"
  address="$(extract_conf_value Interface Address "$file")"
  dns="$(extract_conf_value Interface DNS "$file")"
  mtu="$(extract_conf_value Interface MTU "$file")"

  public_key="$(extract_conf_value Peer PublicKey "$file")"
  preshared_key="$(extract_conf_value Peer PresharedKey "$file")"
  allowed_ips="$(extract_conf_value Peer AllowedIPs "$file")"
  endpoint="$(extract_conf_value Peer Endpoint "$file")"
  keepalive="$(extract_conf_value Peer PersistentKeepalive "$file")"
  jc="$(extract_conf_value Peer Jc "$file")"
  jmin="$(extract_conf_value Peer Jmin "$file")"
  jmax="$(extract_conf_value Peer Jmax "$file")"
  s1="$(extract_conf_value Peer S1 "$file")"
  s2="$(extract_conf_value Peer S2 "$file")"
  s3="$(extract_conf_value Peer S3 "$file")"
  s4="$(extract_conf_value Peer S4 "$file")"
  h1="$(extract_conf_value Peer H1 "$file")"
  h2="$(extract_conf_value Peer H2 "$file")"
  h3="$(extract_conf_value Peer H3 "$file")"
  h4="$(extract_conf_value Peer H4 "$file")"
  i1="$(extract_conf_value Peer I1 "$file")"
  i2="$(extract_conf_value Peer I2 "$file")"
  i3="$(extract_conf_value Peer I3 "$file")"
  i4="$(extract_conf_value Peer I4 "$file")"
  i5="$(extract_conf_value Peer I5 "$file")"

  endpoint_host=""
  endpoint_port=""
  [ -n "$endpoint" ] && endpoint_host="$(split_endpoint_host "$endpoint")"
  [ -n "$endpoint" ] && endpoint_port="$(split_endpoint_port "$endpoint")"

  log "configuring $iface from $(basename "$file")"

  uci -q delete "network.$iface"
  uci -q delete "network.${iface}_peer"

  uci set "network.$iface=interface"
  uci set "network.$iface.proto=amneziawg"
  uci_set_if_present "network.$iface.private_key" "$private_key"
  uci_set_if_present "network.$iface.addresses" "$address"
  uci_set_if_present "network.$iface.dns" "$dns"
  uci_set_if_present "network.$iface.mtu" "$mtu"
  uci_set_if_present "network.$iface.metric" "$metric"

  if [ "$iface" = "awg0" ]; then
    uci_set_if_present "network.$iface.ip4table" "$table"
  fi

  uci set "network.${iface}_peer=amneziawg_${iface}"
  uci set "network.${iface}_peer.public_key=${public_key}"
  uci_set_if_present "network.${iface}_peer.preshared_key" "$preshared_key"
  uci_set_if_present "network.${iface}_peer.allowed_ips" "$allowed_ips"
  uci_set_if_present "network.${iface}_peer.endpoint_host" "$endpoint_host"
  uci_set_if_present "network.${iface}_peer.endpoint_port" "$endpoint_port"
  uci_set_if_present "network.${iface}_peer.persistent_keepalive" "$keepalive"
  uci_set_if_present "network.${iface}_peer.jc" "$jc"
  uci_set_if_present "network.${iface}_peer.jmin" "$jmin"
  uci_set_if_present "network.${iface}_peer.jmax" "$jmax"
  uci_set_if_present "network.${iface}_peer.s1" "$s1"
  uci_set_if_present "network.${iface}_peer.s2" "$s2"
  uci_set_if_present "network.${iface}_peer.s3" "$s3"
  uci_set_if_present "network.${iface}_peer.s4" "$s4"
  uci_set_if_present "network.${iface}_peer.h1" "$h1"
  uci_set_if_present "network.${iface}_peer.h2" "$h2"
  uci_set_if_present "network.${iface}_peer.h3" "$h3"
  uci_set_if_present "network.${iface}_peer.h4" "$h4"
  uci_set_if_present "network.${iface}_peer.i1" "$i1"
  uci_set_if_present "network.${iface}_peer.i2" "$i2"
  uci_set_if_present "network.${iface}_peer.i3" "$i3"
  uci_set_if_present "network.${iface}_peer.i4" "$i4"
  uci_set_if_present "network.${iface}_peer.i5" "$i5"

  if ! uci -q get firewall.${iface}_zone >/dev/null 2>&1; then
    uci set "firewall.${iface}_zone=zone"
    uci set "firewall.${iface}_zone.name=$iface"
    uci set "firewall.${iface}_zone.network=$iface"
    uci set "firewall.${iface}_zone.input=REJECT"
    uci set "firewall.${iface}_zone.output=ACCEPT"
    uci set "firewall.${iface}_zone.forward=REJECT"
    uci set "firewall.${iface}_zone.masq=1"
    uci set "firewall.${iface}_zone.mtu_fix=1"
  fi

  if ! uci -q get firewall.lan_to_${iface} >/dev/null 2>&1; then
    uci set "firewall.lan_to_${iface}=forwarding"
    uci set "firewall.lan_to_${iface}.src=lan"
    uci set "firewall.lan_to_${iface}.dest=$iface"
  fi
}

final_apply() {
  log "committing UCI"
  uci commit network
  uci commit firewall
  uci commit dhcp || true

  log "final apply"
  /etc/init.d/network reload || /etc/init.d/network restart || true
  /etc/init.d/firewall restart || true
  /etc/init.d/dnsmasq restart || true
  [ -x /etc/init.d/getdomains ] && /etc/init.d/getdomains enable || true
  [ -x /etc/init.d/getdomains ] && /etc/init.d/getdomains start || true
  [ -x /usr/bin/vpn-mode-apply ] && /usr/bin/vpn-mode-apply || true
}

main() {
  require_input

  run_vendor_installer amneziawg-install.sh
  run_vendor_installer vpn-mode-install.sh

  configure_iface_from_conf awg0 "$AWG0_CONF" 10 vpn
  configure_iface_from_conf awg1 "$AWG1_CONF" 20 main

  final_apply
  log "done"
}

main "$@"
