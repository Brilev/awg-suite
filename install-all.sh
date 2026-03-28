#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKDIR="${AWG_WORKDIR:-$PWD}"
VENDOR_DIR="$REPO_DIR/vendor"

AWG0_CONF="$WORKDIR/awg0.conf"
AWG1_CONF="$WORKDIR/awg1.conf"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

need_file() {
  [ -f "$1" ] || {
    echo "ERROR: required file not found: $1" >&2
    exit 1
  }
}

need_cmd uci
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd cut
need_cmd tr
need_cmd dirname
need_file "$VENDOR_DIR/amneziawg-install.sh"
need_file "$VENDOR_DIR/vpn-mode-install.sh"

if [ ! -f "$AWG0_CONF" ] && [ ! -f "$AWG1_CONF" ]; then
  echo "ERROR: neither ./awg0.conf nor ./awg1.conf was found in current directory: $WORKDIR" >&2
  exit 1
fi

parse_conf_value() {
  file="$1"
  section="$2"
  key="$3"

  awk -F '=' -v target_section="$section" -v target_key="$key" '
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
    current == target_section {
      line=$0
      pos=index(line, "=")
      if (pos > 0) {
        k=trim(substr(line, 1, pos-1))
        v=trim(substr(line, pos+1))
        if (k == target_key) {
          print v
          exit
        }
      }
    }
  ' "$file"
}

split_endpoint_host() {
  endpoint="$1"
  echo "$endpoint" | sed 's/:[0-9][0-9]*$//'
}

split_endpoint_port() {
  endpoint="$1"
  echo "$endpoint" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p'
}

uci_delete_if_exists() {
  section="$1"
  if uci -q get "$section" >/dev/null 2>&1; then
    uci -q delete "$section"
  fi
}

configure_awg_iface() {
  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  private_key="$(parse_conf_value "$conf" Interface PrivateKey)"
  address="$(parse_conf_value "$conf" Interface Address)"
  dns="$(parse_conf_value "$conf" Interface DNS)"

  public_key="$(parse_conf_value "$conf" Peer PublicKey)"
  preshared_key="$(parse_conf_value "$conf" Peer PresharedKey)"
  allowed_ips="$(parse_conf_value "$conf" Peer AllowedIPs)"
  endpoint="$(parse_conf_value "$conf" Peer Endpoint)"
  keepalive="$(parse_conf_value "$conf" Peer PersistentKeepalive)"

  jc="$(parse_conf_value "$conf" Peer Jc)"
  jmin="$(parse_conf_value "$conf" Peer Jmin)"
  jmax="$(parse_conf_value "$conf" Peer Jmax)"
  s1="$(parse_conf_value "$conf" Peer S1)"
  s2="$(parse_conf_value "$conf" Peer S2)"
  h1="$(parse_conf_value "$conf" Peer H1)"
  h2="$(parse_conf_value "$conf" Peer H2)"
  h3="$(parse_conf_value "$conf" Peer H3)"
  h4="$(parse_conf_value "$conf" Peer H4)"

  endpoint_host="$(split_endpoint_host "$endpoint")"
  endpoint_port="$(split_endpoint_port "$endpoint")"

  echo "==> Configuring $iface from $(basename "$conf")"

  uci_delete_if_exists "network.$iface"
  uci_delete_if_exists "network.${iface}_peer"

  uci set "network.$iface=interface"
  uci set "network.$iface.proto=amneziawg"
  [ -n "$private_key" ] && uci set "network.$iface.private_key=$private_key"
  [ -n "$address" ] && uci set "network.$iface.addresses=$address"
  [ -n "$dns" ] && uci set "network.$iface.dns=$dns"

  uci set "network.${iface}_peer=amneziawg_${iface}"
  uci set "network.${iface}_peer.public_key=$public_key"
  [ -n "$preshared_key" ] && uci set "network.${iface}_peer.preshared_key=$preshared_key"
  [ -n "$allowed_ips" ] && uci set "network.${iface}_peer.allowed_ips=$allowed_ips"
  [ -n "$endpoint_host" ] && uci set "network.${iface}_peer.endpoint_host=$endpoint_host"
  [ -n "$endpoint_port" ] && uci set "network.${iface}_peer.endpoint_port=$endpoint_port"
  [ -n "$keepalive" ] && uci set "network.${iface}_peer.persistent_keepalive=$keepalive"

  [ -n "$jc" ] && uci set "network.${iface}.jc=$jc"
  [ -n "$jmin" ] && uci set "network.${iface}.jmin=$jmin"
  [ -n "$jmax" ] && uci set "network.${iface}.jmax=$jmax"
  [ -n "$s1" ] && uci set "network.${iface}.s1=$s1"
  [ -n "$s2" ] && uci set "network.${iface}.s2=$s2"
  [ -n "$h1" ] && uci set "network.${iface}.h1=$h1"
  [ -n "$h2" ] && uci set "network.${iface}.h2=$h2"
  [ -n "$h3" ] && uci set "network.${iface}.h3=$h3"
  [ -n "$h4" ] && uci set "network.${iface}.h4=$h4"

  if ! uci -q get firewall.${iface}_zone >/dev/null 2>&1; then
    uci add firewall zone >/dev/null
    last_zone="$(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p' | tail -n1)"
    [ -n "$last_zone" ] && uci rename "firewall.$last_zone=${iface}_zone"
  fi

  uci set "firewall.${iface}_zone=zone"
  uci set "firewall.${iface}_zone.name=$iface"
  uci set "firewall.${iface}_zone.network=$iface"
  uci set "firewall.${iface}_zone.input=REJECT"
  uci set "firewall.${iface}_zone.output=ACCEPT"
  uci set "firewall.${iface}_zone.forward=REJECT"
  uci set "firewall.${iface}_zone.masq=1"
  uci set "firewall.${iface}_zone.mtu_fix=1"
}

run_vendor_installer() {
  file="$1"
  name="$(basename "$file")"
  echo "==> Running vendor installer: $name"
  chmod +x "$file"
  sh "$file" || {
    echo "WARNING: vendor installer failed: $name" >&2
    return 1
  }
  return 0
}

echo "==> Workdir: $WORKDIR"
echo "==> Repo dir: $REPO_DIR"

run_vendor_installer "$VENDOR_DIR/amneziawg-install.sh" || true
run_vendor_installer "$VENDOR_DIR/vpn-mode-install.sh" || true

configure_awg_iface awg0 "$AWG0_CONF"
configure_awg_iface awg1 "$AWG1_CONF"

echo "==> Applying UCI changes"
uci commit network
uci commit firewall
uci commit dhcp || true

/etc/init.d/network reload || /etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart || true

if [ -x /etc/init.d/getdomains ]; then
  /etc/init.d/getdomains enable || true
fi

if [ -x /usr/bin/vpn-mode-apply ]; then
  /usr/bin/vpn-mode-apply || true
fi

echo "==> Done"
