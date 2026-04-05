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

log() {
  echo "==> $*"
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

  awk -v target_section="$section" -v target_key="$key" '
    function trim(s) {
      sub(/^[ \t\r\n]+/, "", s)
      sub(/[ \t\r\n]+$/, "", s)
      return s
    }

    /^\[/ {
      current=$0
      gsub(/^\[/, "", current)
      gsub(/\]$/, "", current)
      current=trim(current)
      next
    }

    current == target_section {
      line=$0
      pos=index(line, "=")
      if (pos > 0) {
        k=trim(substr(line, 1, pos - 1))
        v=trim(substr(line, pos + 1))
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

uci_set_opt() {
  key="$1"
  value="$2"
  [ -n "$value" ] || return 0
  uci set "$key=$value"
}

find_zone_sections_by_name() {
  zone_name="$1"
  uci show firewall 2>/dev/null \
    | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p" \
    | while read -r sec; do
        [ -n "$sec" ] || continue
        name="$(uci -q get firewall."$sec".name || true)"
        [ "$name" = "$zone_name" ] && echo "$sec"
      done
}

find_zone_sections_by_network() {
  net="$1"
  uci show firewall 2>/dev/null \
    | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p" \
    | while read -r sec; do
        [ -n "$sec" ] || continue
        networks="$(uci -q get firewall."$sec".network || true)"
        for n in $networks; do
          if [ "$n" = "$net" ]; then
            echo "$sec"
            break
          fi
        done
      done
}

remove_duplicate_zones() {
  keep_section="$1"
  zone_name="$2"
  net="$3"

  for sec in $(find_zone_sections_by_name "$zone_name"; find_zone_sections_by_network "$net"); do
    [ -n "$sec" ] || continue
    [ "$sec" = "$keep_section" ] && continue
    uci -q delete "firewall.$sec" || true
  done
}

ensure_named_zone() {
  iface="$1"
  section="${iface}_zone"

  remove_duplicate_zones "$section" "$iface" "$iface"

  uci_delete_if_exists "firewall.$section"
  uci set "firewall.$section=zone"
  uci set "firewall.$section.name=$iface"
  uci set "firewall.$section.network=$iface"
  uci set "firewall.$section.input=REJECT"
  uci set "firewall.$section.output=ACCEPT"
  uci set "firewall.$section.forward=REJECT"
  uci set "firewall.$section.masq=1"
  uci set "firewall.$section.mtu_fix=1"
  uci set "firewall.$section.family=ipv4"
}

configure_awg_iface() {
  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  private_key="$(parse_conf_value "$conf" Interface PrivateKey)"
  address="$(parse_conf_value "$conf" Interface Address)"
  dns="$(parse_conf_value "$conf" Interface DNS)"
  jc="$(parse_conf_value "$conf" Interface Jc)"
  jmin="$(parse_conf_value "$conf" Interface Jmin)"
  jmax="$(parse_conf_value "$conf" Interface Jmax)"
  s1="$(parse_conf_value "$conf" Interface S1)"
  s2="$(parse_conf_value "$conf" Interface S2)"
  h1="$(parse_conf_value "$conf" Interface H1)"
  h2="$(parse_conf_value "$conf" Interface H2)"
  h3="$(parse_conf_value "$conf" Interface H3)"
  h4="$(parse_conf_value "$conf" Interface H4)"
  s3="$(parse_conf_value "$conf" Interface S3)"
  s4="$(parse_conf_value "$conf" Interface S4)"
  i1="$(parse_conf_value "$conf" Interface I1)"
  i2="$(parse_conf_value "$conf" Interface I2)"
  i3="$(parse_conf_value "$conf" Interface I3)"
  i4="$(parse_conf_value "$conf" Interface I4)"
  i5="$(parse_conf_value "$conf" Interface I5)"

  public_key="$(parse_conf_value "$conf" Peer PublicKey)"
  preshared_key="$(parse_conf_value "$conf" Peer PresharedKey)"
  allowed_ips="$(parse_conf_value "$conf" Peer AllowedIPs)"
  endpoint="$(parse_conf_value "$conf" Peer Endpoint)"
  keepalive="$(parse_conf_value "$conf" Peer PersistentKeepalive)"

  endpoint_host="$(split_endpoint_host "$endpoint")"
  endpoint_port="$(split_endpoint_port "$endpoint")"

  log "Configuring $iface from $(basename "$conf")"

  uci_delete_if_exists "network.$iface"
  uci_delete_if_exists "network.${iface}_peer"

  uci set "network.$iface=interface"
  uci set "network.$iface.proto=amneziawg"

  uci_set_opt "network.$iface.private_key" "$private_key"
  uci_set_opt "network.$iface.addresses" "$address"
  uci_set_opt "network.$iface.dns" "$dns"

  uci_set_opt "network.$iface.awg_jc" "$jc"
  uci_set_opt "network.$iface.awg_jmin" "$jmin"
  uci_set_opt "network.$iface.awg_jmax" "$jmax"
  uci_set_opt "network.$iface.awg_s1" "$s1"
  uci_set_opt "network.$iface.awg_s2" "$s2"
  uci_set_opt "network.$iface.awg_h1" "$h1"
  uci_set_opt "network.$iface.awg_h2" "$h2"
  uci_set_opt "network.$iface.awg_h3" "$h3"
  uci_set_opt "network.$iface.awg_h4" "$h4"
  uci_set_opt "network.$iface.awg_s3" "$s3"
  uci_set_opt "network.$iface.awg_s4" "$s4"
  uci_set_opt "network.$iface.awg_i1" "$i1"
  uci_set_opt "network.$iface.awg_i2" "$i2"
  uci_set_opt "network.$iface.awg_i3" "$i3"
  uci_set_opt "network.$iface.awg_i4" "$i4"
  uci_set_opt "network.$iface.awg_i5" "$i5"

  uci set "network.${iface}_peer=amneziawg_${iface}"
  uci_set_opt "network.${iface}_peer.public_key" "$public_key"
  uci_set_opt "network.${iface}_peer.preshared_key" "$preshared_key"
  uci_set_opt "network.${iface}_peer.allowed_ips" "$allowed_ips"
  uci_set_opt "network.${iface}_peer.endpoint_host" "$endpoint_host"
  uci_set_opt "network.${iface}_peer.endpoint_port" "$endpoint_port"
  uci_set_opt "network.${iface}_peer.persistent_keepalive" "$keepalive"

  ensure_named_zone "$iface"
}

run_vendor_installer() {
  file="$1"
  name="$(basename "$file")"

  log "Running vendor installer: $name"
  chmod +x "$file"

  case "$name" in
    amneziawg-install.sh)
      # 1) Install Russian language pack? -> n
      # 2) Do you want to configure the amneziawg interface? -> n
      printf 'n\nn\n' | sh "$file" || {
        echo "WARNING: vendor installer failed: $name" >&2
        return 1
      }
      ;;
    *)
      sh "$file" || {
        echo "WARNING: vendor installer failed: $name" >&2
        return 1
      }
      ;;
  esac

  return 0
}

log "Workdir: $WORKDIR"
log "Repo dir: $REPO_DIR"

# 1. Install AWG packages only, without interactive interface config
run_vendor_installer "$VENDOR_DIR/amneziawg-install.sh" || true

# 2. Create interfaces from awg0.conf / awg1.conf
configure_awg_iface awg0 "$AWG0_CONF"
configure_awg_iface awg1 "$AWG1_CONF"

# 3. Commit network/firewall before vpn-mode installer
log "Applying UCI changes"
uci commit network
uci commit firewall
uci commit dhcp || true

# 4. Run vpn-mode installer only after network.awg0 / network.awg1 exist
run_vendor_installer "$VENDOR_DIR/vpn-mode-install.sh" || true

# 5. Final commit after vendor scripts
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

log "Done"
