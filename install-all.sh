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

warn() {
  echo "WARNING: $*" >&2
}

need_cmd uci
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

trim() {
  local v
  v="$1"
  v="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s' "$v"
}

join_file_to_one_line() {
  local file
  file="$1"
  sed ':a;N;$!ba;s/\r//g;s/\n/ /g;s/[[:space:]][[:space:]]*/ /g' "$file"
}

extract_section_blob() {
  local flat section rest blob
  flat="$1"
  section="$2"

  case "$section" in
    Interface)
      rest="${flat#*\[Interface\]}"
      [ "$rest" = "$flat" ] && { printf '%s' ""; return 0; }
      blob="${rest%%\[Peer\]*}"
      ;;
    Peer)
      rest="${flat#*\[Peer\]}"
      [ "$rest" = "$flat" ] && { printf '%s' ""; return 0; }
      blob="$rest"
      ;;
    *)
      printf '%s' ""
      return 0
      ;;
  esac

  blob="$(trim "$blob")"
  printf '%s' "$blob"
}

normalize_blob_lines() {
  local blob kind
  blob="$1"
  kind="$2"

  blob=" $(trim "$blob") "

  if [ "$kind" = "interface" ]; then
    printf '%s' "$blob" | sed \
      -e 's/^ *Address *= */Address=/g' \
      -e 's/ Address *= */\
Address=/g' \
      -e 's/ DNS *= */\
DNS=/g' \
      -e 's/ PrivateKey *= */\
PrivateKey=/g' \
      -e 's/ Jc *= */\
Jc=/g' \
      -e 's/ Jmin *= */\
Jmin=/g' \
      -e 's/ Jmax *= */\
Jmax=/g' \
      -e 's/ S1 *= */\
S1=/g' \
      -e 's/ S2 *= */\
S2=/g' \
      -e 's/ S3 *= */\
S3=/g' \
      -e 's/ S4 *= */\
S4=/g' \
      -e 's/ H1 *= */\
H1=/g' \
      -e 's/ H2 *= */\
H2=/g' \
      -e 's/ H3 *= */\
H3=/g' \
      -e 's/ H4 *= */\
H4=/g' \
      -e 's/ I1 *= */\
I1=/g' \
      -e 's/ I2 *= */\
I2=/g' \
      -e 's/ I3 *= */\
I3=/g' \
      -e 's/ I4 *= */\
I4=/g' \
      -e 's/ I5 *= */\
I5=/g' \
      -e 's/^[[:space:]]*//; s/[[:space:]]*$//'
  else
    printf '%s' "$blob" | sed \
      -e 's/^ *PublicKey *= */PublicKey=/g' \
      -e 's/ PublicKey *= */\
PublicKey=/g' \
      -e 's/ PresharedKey *= */\
PresharedKey=/g' \
      -e 's/ AllowedIPs *= */\
AllowedIPs=/g' \
      -e 's/ Endpoint *= */\
Endpoint=/g' \
      -e 's/ PersistentKeepalive *= */\
PersistentKeepalive=/g' \
      -e 's/^[[:space:]]*//; s/[[:space:]]*$//'
  fi
}

get_line_value() {
  local lines key line
  lines="$1"
  key="$2"
  line="$(printf '%s\n' "$lines" | sed -n "s/^${key}=//p" | head -n 1)"
  printf '%s' "$line"
}

split_csv_to_lines() {
  local value
  value="$1"
  printf '%s' "$value" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
}

split_endpoint_host() {
  local endpoint
  endpoint="$1"
  printf '%s' "$endpoint" | sed 's/:[0-9][0-9]*$//'
}

split_endpoint_port() {
  local endpoint
  endpoint="$1"
  printf '%s' "$endpoint" | sed -n 's/^.*:\([0-9][0-9]*\)$/\1/p'
}

uci_delete_if_exists() {
  local section
  section="$1"
  if uci -q get "$section" >/dev/null 2>&1; then
    log "uci delete $section"
    uci -q delete "$section" || true
  fi
}

uci_set_logged() {
  local key value
  key="$1"
  value="$2"
  [ -n "${value}" ] || return 0
  log "uci set $key = [$value]"
  uci set "$key=$value" || {
    warn "failed: uci set $key=[$value]"
    return 1
  }
}

uci_add_list_logged() {
  local key value
  key="$1"
  value="$2"
  [ -n "${value}" ] || return 0
  log "uci add_list $key = [$value]"
  uci add_list "$key=$value" || {
    warn "failed: uci add_list $key=[$value]"
    return 1
  }
}

uci_set_csv_list() {
  local key csv item
  key="$1"
  csv="$2"
  [ -n "${csv}" ] || return 0
  OLD_IFS="$IFS"
  IFS='\n'
  for item in $(split_csv_to_lines "$csv"); do
    item="$(trim "$item")"
    [ -n "$item" ] || continue
    uci_add_list_logged "$key" "$item" || {
      IFS="$OLD_IFS"
      return 1
    }
  done
  IFS="$OLD_IFS"
}

find_zone_sections_by_name() {
  local zone_name sec name
  zone_name="$1"
  uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' | while read -r sec; do
    [ -n "$sec" ] || continue
    name="$(uci -q get firewall."$sec".name || true)"
    [ "$name" = "$zone_name" ] && echo "$sec"
  done
}

find_zone_sections_by_network() {
  local net sec networks n
  net="$1"
  uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' | while read -r sec; do
    [ -n "$sec" ] || continue
    networks="$(uci -q get firewall."$sec".network || true)"
    for n in $networks; do
      [ "$n" = "$net" ] && {
        echo "$sec"
        break
      }
    done
  done
}

remove_duplicate_zones() {
  local keep_section zone_name net sec
  keep_section="$1"
  zone_name="$2"
  net="$3"

  for sec in $(find_zone_sections_by_name "$zone_name"; find_zone_sections_by_network "$net"); do
    [ -n "$sec" ] || continue
    [ "$sec" = "$keep_section" ] && continue
    log "uci delete firewall.$sec (duplicate zone)"
    uci -q delete "firewall.$sec" || true
  done
}

ensure_named_zone() {
  local iface section
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
  local iface conf flat interface_blob peer_blob interface_lines peer_lines
  local private_key address dns jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
  local public_key preshared_key allowed_ips endpoint keepalive endpoint_host endpoint_port
  local peer_section sec

  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  flat="$(join_file_to_one_line "$conf")"
  interface_blob="$(extract_section_blob "$flat" Interface)"
  peer_blob="$(extract_section_blob "$flat" Peer)"
  interface_lines="$(normalize_blob_lines "$interface_blob" interface)"
  peer_lines="$(normalize_blob_lines "$peer_blob" peer)"

  log "Configuring $iface from $(basename "$conf")"
  log "Parsed Interface blob: [$interface_blob]"
  log "Parsed Peer blob: [$peer_blob]"

  address="$(get_line_value "$interface_lines" Address)"
  dns="$(get_line_value "$interface_lines" DNS)"
  private_key="$(get_line_value "$interface_lines" PrivateKey)"
  jc="$(get_line_value "$interface_lines" Jc)"
  jmin="$(get_line_value "$interface_lines" Jmin)"
  jmax="$(get_line_value "$interface_lines" Jmax)"
  s1="$(get_line_value "$interface_lines" S1)"
  s2="$(get_line_value "$interface_lines" S2)"
  s3="$(get_line_value "$interface_lines" S3)"
  s4="$(get_line_value "$interface_lines" S4)"
  h1="$(get_line_value "$interface_lines" H1)"
  h2="$(get_line_value "$interface_lines" H2)"
  h3="$(get_line_value "$interface_lines" H3)"
  h4="$(get_line_value "$interface_lines" H4)"
  i1="$(get_line_value "$interface_lines" I1)"
  i2="$(get_line_value "$interface_lines" I2)"
  i3="$(get_line_value "$interface_lines" I3)"
  i4="$(get_line_value "$interface_lines" I4)"
  i5="$(get_line_value "$interface_lines" I5)"

  public_key="$(get_line_value "$peer_lines" PublicKey)"
  preshared_key="$(get_line_value "$peer_lines" PresharedKey)"
  allowed_ips="$(get_line_value "$peer_lines" AllowedIPs)"
  endpoint="$(get_line_value "$peer_lines" Endpoint)"
  keepalive="$(get_line_value "$peer_lines" PersistentKeepalive)"

  endpoint_host="$(split_endpoint_host "$endpoint")"
  endpoint_port="$(split_endpoint_port "$endpoint")"

  uci_delete_if_exists "network.$iface"

  uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=amneziawg_.*$/\1/p' | while read -r sec; do
    [ -n "$sec" ] || continue
    if [ "$(uci -q get network.$sec.interface || true)" = "$iface" ]; then
      log "uci delete network.$sec (old peer section)"
      uci -q delete "network.$sec" || true
    fi
  done

  uci_set_logged "network.$iface" "interface"
  uci_set_logged "network.$iface.proto" "amneziawg"
  uci_set_logged "network.$iface.private_key" "$private_key"
  uci_set_csv_list "network.$iface.addresses" "$address"
  uci_set_csv_list "network.$iface.dns" "$dns"

  uci_set_logged "network.$iface.awg_jc" "$jc"
  uci_set_logged "network.$iface.awg_jmin" "$jmin"
  uci_set_logged "network.$iface.awg_jmax" "$jmax"
  uci_set_logged "network.$iface.awg_s1" "$s1"
  uci_set_logged "network.$iface.awg_s2" "$s2"
  uci_set_logged "network.$iface.awg_s3" "$s3"
  uci_set_logged "network.$iface.awg_s4" "$s4"
  uci_set_logged "network.$iface.awg_h1" "$h1"
  uci_set_logged "network.$iface.awg_h2" "$h2"
  uci_set_logged "network.$iface.awg_h3" "$h3"
  uci_set_logged "network.$iface.awg_h4" "$h4"
  uci_set_logged "network.$iface.awg_i1" "$i1"
  uci_set_logged "network.$iface.awg_i2" "$i2"
  uci_set_logged "network.$iface.awg_i3" "$i3"
  uci_set_logged "network.$iface.awg_i4" "$i4"
  uci_set_logged "network.$iface.awg_i5" "$i5"

  peer_section="$(uci add network "amneziawg_$iface")"
  log "uci add network amneziawg_$iface -> [$peer_section]"
  uci_set_logged "network.$peer_section.interface" "$iface"
  uci_set_logged "network.$peer_section.public_key" "$public_key"
  uci_set_logged "network.$peer_section.preshared_key" "$preshared_key"
  uci_set_csv_list "network.$peer_section.allowed_ips" "$allowed_ips"
  uci_set_logged "network.$peer_section.endpoint_host" "$endpoint_host"
  uci_set_logged "network.$peer_section.endpoint_port" "$endpoint_port"
  uci_set_logged "network.$peer_section.persistent_keepalive" "$keepalive"

  ensure_named_zone "$iface"
}

run_vendor_installer() {
  local file name
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
