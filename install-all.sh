#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKDIR="${AWG_WORKDIR:-$PWD}"
VENDOR_DIR="$REPO_DIR/vendor"

AWG0_CONF="$WORKDIR/awg0.conf"
AWG1_CONF="$WORKDIR/awg1.conf"
DEBUG_UCI="${DEBUG_UCI:-1}"

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

warn() {
  echo "WARNING: $*" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd uci
need_cmd sed
need_cmd grep
need_cmd cut
need_cmd tr
need_cmd dirname
need_cmd mktemp

need_file "$VENDOR_DIR/amneziawg-install.sh"
need_file "$VENDOR_DIR/vpn-mode-install.sh"

if [ ! -f "$AWG0_CONF" ] && [ ! -f "$AWG1_CONF" ]; then
  fail "neither ./awg0.conf nor ./awg1.conf was found in current directory: $WORKDIR"
fi

trim() {
  val="$1"
  # shellcheck disable=SC2001
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s' "$val"
}

flatten_conf() {
  file="$1"
  tr '\r\n' '  ' < "$file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

extract_section_blob() {
  flat="$1"
  section="$2"
  marker="[$section]"

  case "$flat" in
    *"$marker"*) ;;
    *)
      printf '%s' ""
      return 0
      ;;
  esac

  rest="${flat#*"$marker"}"
  case "$rest" in
    *"["*) rest="${rest%%\[*}" ;;
  esac

  trim "$rest"
}

blob_to_lines() {
  blob="$1"
  printf '%s' "$blob" \
    | sed -E 's/[[:space:]]+([A-Za-z][A-Za-z0-9]*)[[:space:]]*=[[:space:]]*/\
\1=/g' \
    | sed '1s/^[[:space:]]*//'
}

get_blob_value() {
  blob="$1"
  key="$2"

  lines="$(blob_to_lines "$blob")"
  line="$(printf '%s\n' "$lines" | grep -m1 "^${key}=" || true)"
  [ -n "$line" ] || {
    printf '%s' ""
    return 0
  }

  printf '%s' "${line#*=}"
}

split_csv_to_lines() {
  value="$1"
  printf '%s' "$value" | tr ',' '\n' | while IFS= read -r item; do
    item="$(trim "$item")"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
}

split_endpoint_host() {
  endpoint="$1"
  printf '%s' "$endpoint" | sed 's/:[0-9][0-9]*$//'
}

split_endpoint_port() {
  endpoint="$1"
  printf '%s' "$endpoint" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p'
}

uci_delete_if_exists() {
  section="$1"
  if uci -q get "$section" >/dev/null 2>&1; then
    log "uci delete $section"
    uci -q delete "$section"
  fi
}

uci_set_logged() {
  key="$1"
  value="$2"
  log "uci set ${key} = [${value}]"
  if ! uci set "${key}=${value}"; then
    warn "failed: uci set ${key}=[${value}]"
    return 1
  fi
}

uci_add_list_logged() {
  key="$1"
  value="$2"
  log "uci add_list ${key} = [${value}]"
  if ! uci add_list "${key}=${value}"; then
    warn "failed: uci add_list ${key}=[${value}]"
    return 1
  fi
}

uci_set_if_present() {
  key="$1"
  value="$2"
  [ -n "$value" ] || return 0
  uci_set_logged "$key" "$value"
}

find_zone_sections_by_name() {
  zone_name="$1"
  uci show firewall 2>/dev/null \
    | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' \
    | while read -r sec; do
        [ -n "$sec" ] || continue
        name="$(uci -q get firewall."$sec".name || true)"
        [ "$name" = "$zone_name" ] && echo "$sec"
      done
}

find_zone_sections_by_network() {
  net="$1"
  uci show firewall 2>/dev/null \
    | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' \
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
    log "uci delete firewall.$sec (duplicate zone for $zone_name/$net)"
    uci -q delete "firewall.$sec" || true
  done
}

ensure_named_zone() {
  iface="$1"
  section="${iface}_zone"

  remove_duplicate_zones "$section" "$iface" "$iface"

  uci_delete_if_exists "firewall.$section"
  uci_set_logged "firewall.$section" "zone"
  uci_set_logged "firewall.$section.name" "$iface"
  uci_set_logged "firewall.$section.network" "$iface"
  uci_set_logged "firewall.$section.input" "REJECT"
  uci_set_logged "firewall.$section.output" "ACCEPT"
  uci_set_logged "firewall.$section.forward" "REJECT"
  uci_set_logged "firewall.$section.masq" "1"
  uci_set_logged "firewall.$section.mtu_fix" "1"
  uci_set_logged "firewall.$section.family" "ipv4"
}

configure_awg_iface() {
  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  flat="$(flatten_conf "$conf")"
  interface_blob="$(extract_section_blob "$flat" "Interface")"
  peer_blob="$(extract_section_blob "$flat" "Peer")"

  log "Configuring $iface from $(basename "$conf")"
  log "Parsed Interface blob: [$interface_blob]"
  log "Parsed Peer blob: [$peer_blob]"

  private_key="$(get_blob_value "$interface_blob" "PrivateKey")"
  address="$(get_blob_value "$interface_blob" "Address")"
  dns="$(get_blob_value "$interface_blob" "DNS")"
  jc="$(get_blob_value "$interface_blob" "Jc")"
  jmin="$(get_blob_value "$interface_blob" "Jmin")"
  jmax="$(get_blob_value "$interface_blob" "Jmax")"
  s1="$(get_blob_value "$interface_blob" "S1")"
  s2="$(get_blob_value "$interface_blob" "S2")"
  s3="$(get_blob_value "$interface_blob" "S3")"
  s4="$(get_blob_value "$interface_blob" "S4")"
  h1="$(get_blob_value "$interface_blob" "H1")"
  h2="$(get_blob_value "$interface_blob" "H2")"
  h3="$(get_blob_value "$interface_blob" "H3")"
  h4="$(get_blob_value "$interface_blob" "H4")"
  i1="$(get_blob_value "$interface_blob" "I1")"
  i2="$(get_blob_value "$interface_blob" "I2")"
  i3="$(get_blob_value "$interface_blob" "I3")"
  i4="$(get_blob_value "$interface_blob" "I4")"
  i5="$(get_blob_value "$interface_blob" "I5")"

  public_key="$(get_blob_value "$peer_blob" "PublicKey")"
  preshared_key="$(get_blob_value "$peer_blob" "PresharedKey")"
  allowed_ips="$(get_blob_value "$peer_blob" "AllowedIPs")"
  endpoint="$(get_blob_value "$peer_blob" "Endpoint")"
  keepalive="$(get_blob_value "$peer_blob" "PersistentKeepalive")"

  endpoint_host="$(split_endpoint_host "$endpoint")"
  endpoint_port="$(split_endpoint_port "$endpoint")"

  uci_delete_if_exists "network.$iface"
  uci_delete_if_exists "network.${iface}_peer"

  uci_set_logged "network.$iface" "interface"
  uci_set_logged "network.$iface.proto" "amneziawg"
  uci_set_if_present "network.$iface.private_key" "$private_key"

  if [ -n "$address" ]; then
    split_csv_to_lines "$address" | while IFS= read -r item; do
      uci_add_list_logged "network.$iface.addresses" "$item" || exit 1
    done
  fi

  if [ -n "$dns" ]; then
    split_csv_to_lines "$dns" | while IFS= read -r item; do
      uci_add_list_logged "network.$iface.dns" "$item" || exit 1
    done
  fi

  uci_set_if_present "network.$iface.awg_jc" "$jc"
  uci_set_if_present "network.$iface.awg_jmin" "$jmin"
  uci_set_if_present "network.$iface.awg_jmax" "$jmax"
  uci_set_if_present "network.$iface.awg_s1" "$s1"
  uci_set_if_present "network.$iface.awg_s2" "$s2"
  uci_set_if_present "network.$iface.awg_s3" "$s3"
  uci_set_if_present "network.$iface.awg_s4" "$s4"
  uci_set_if_present "network.$iface.awg_h1" "$h1"
  uci_set_if_present "network.$iface.awg_h2" "$h2"
  uci_set_if_present "network.$iface.awg_h3" "$h3"
  uci_set_if_present "network.$iface.awg_h4" "$h4"
  uci_set_if_present "network.$iface.awg_i1" "$i1"
  uci_set_if_present "network.$iface.awg_i2" "$i2"
  uci_set_if_present "network.$iface.awg_i3" "$i3"
  uci_set_if_present "network.$iface.awg_i4" "$i4"
  uci_set_if_present "network.$iface.awg_i5" "$i5"

  uci_set_logged "network.${iface}_peer" "amneziawg_${iface}"
  uci_set_if_present "network.${iface}_peer.public_key" "$public_key"
  uci_set_if_present "network.${iface}_peer.preshared_key" "$preshared_key"

  if [ -n "$allowed_ips" ]; then
    split_csv_to_lines "$allowed_ips" | while IFS= read -r item; do
      uci_add_list_logged "network.${iface}_peer.allowed_ips" "$item" || exit 1
    done
  fi

  uci_set_if_present "network.${iface}_peer.endpoint_host" "$endpoint_host"
  uci_set_if_present "network.${iface}_peer.endpoint_port" "$endpoint_port"
  uci_set_if_present "network.${iface}_peer.persistent_keepalive" "$keepalive"

  ensure_named_zone "$iface"
}

run_vendor_installer() {
  file="$1"
  name="$(basename "$file")"

  log "Running vendor installer: $name"
  chmod +x "$file"

  case "$name" in
    amneziawg-install.sh)
      printf 'n\nn\n' | sh "$file" || {
        warn "vendor installer failed: $name"
        return 1
      }
      ;;
    *)
      sh "$file" || {
        warn "vendor installer failed: $name"
        return 1
      }
      ;;
  esac

  return 0
}

log "Workdir: $WORKDIR"
log "Repo dir: $REPO_DIR"

run_vendor_installer "$VENDOR_DIR/amneziawg-install.sh" || true

configure_awg_iface awg0 "$AWG0_CONF"
configure_awg_iface awg1 "$AWG1_CONF"

log "Applying UCI changes"
uci commit network
uci commit firewall
uci commit dhcp || true

run_vendor_installer "$VENDOR_DIR/vpn-mode-install.sh" || true

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
