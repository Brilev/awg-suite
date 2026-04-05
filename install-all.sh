#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKDIR="${AWG_WORKDIR:-$PWD}"
VENDOR_DIR="$REPO_DIR/vendor"

AWG0_CONF="$WORKDIR/awg0.conf"
AWG1_CONF="$WORKDIR/awg1.conf"

INTERFACE_KEYS="Address DNS PrivateKey Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5"
PEER_KEYS="PublicKey PresharedKey AllowedIPs Endpoint PersistentKeepalive"

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

trim() {
  value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

normalize_ini_file() {
  file="$1"
  tr -d '\r' < "$file" \
    | sed -e 's/\[/\n[/g' -e 's/\]/]\n/g'
}

normalize_blob_with_keys() {
  blob="$1"
  keys="$2"
  out=" $blob"
  for key in $keys; do
    out="$(printf '%s' "$out" | sed "s/[[:space:]]${key}[[:space:]]*=/\n${key} =/g")"
  done
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d'
}

extract_section_blob() {
  file="$1"
  section="$2"
  in_section=0
  buffer=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      "[$section]")
        in_section=1
        continue
        ;;
      "["*"]")
        if [ "$in_section" = 1 ]; then
          break
        fi
        ;;
      *)
        if [ "$in_section" = 1 ]; then
          if [ -n "$buffer" ]; then
            buffer="$buffer $line"
          else
            buffer="$line"
          fi
        fi
        ;;
    esac
  done <<EOFSEC
$(normalize_ini_file "$file")
EOFSEC

  printf '%s' "$(trim "$buffer")"
}

get_blob_value() {
  blob="$1"
  keys="$2"
  wanted="$3"
  found=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    case "$line" in
      "$wanted ="*)
        found="${line#*=}"
        found="$(trim "$found")"
        printf '%s' "$found"
        return 0
        ;;
    esac
  done <<EOFVAL
$(normalize_blob_with_keys "$blob" "$keys")
EOFVAL

  printf ''
}

split_csv_to_lines() {
  value="$1"
  old_ifs="$IFS"
  IFS=','
  set -f
  for item in $value; do
    item="$(trim "$item")"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
  set +f
  IFS="$old_ifs"
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
  [ -n "$value" ] || return 0
  log "uci set $key = [$value]"
  if ! uci set "$key=$value"; then
    warn "failed: uci set $key=[$value]"
    return 1
  fi
}

uci_add_list_logged() {
  key="$1"
  value="$2"
  [ -n "$value" ] || return 0
  log "uci add_list $key = [$value]"
  if ! uci add_list "$key=$value"; then
    warn "failed: uci add_list $key=[$value]"
    return 1
  fi
}

uci_add_section_logged() {
  config="$1"
  type="$2"
  sec="$(uci add "$config" "$type")"
  log "uci add $config $type -> [$sec]"
  printf '%s' "$sec"
}

find_zone_sections_by_name() {
  zone_name="$1"
  uci show firewall 2>/dev/null \
    | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' \
    | while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        name="$(uci -q get firewall."$sec".name || true)"
        [ "$name" = "$zone_name" ] && echo "$sec"
      done
}

find_zone_sections_by_network() {
  net="$1"
  uci show firewall 2>/dev/null \
    | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p' \
    | while IFS= read -r sec; do
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
  keep_section="$1"
  zone_name="$2"
  net="$3"

  for sec in $(find_zone_sections_by_name "$zone_name"; find_zone_sections_by_network "$net"); do
    [ -n "$sec" ] || continue
    [ "$sec" = "$keep_section" ] && continue
    log "uci delete firewall.$sec"
    uci -q delete "firewall.$sec" || true
  done
}

ensure_named_zone() {
  iface="$1"
  section="${iface}_zone"

  remove_duplicate_zones "$section" "$iface" "$iface"

  uci_delete_if_exists "firewall.$section"
  log "uci set firewall.$section = [zone]"
  uci set "firewall.$section=zone"
  uci_set_logged "firewall.$section.name" "$iface"
  uci_set_logged "firewall.$section.network" "$iface"
  uci_set_logged "firewall.$section.input" "REJECT"
  uci_set_logged "firewall.$section.output" "ACCEPT"
  uci_set_logged "firewall.$section.forward" "REJECT"
  uci_set_logged "firewall.$section.masq" "1"
  uci_set_logged "firewall.$section.mtu_fix" "1"
  uci_set_logged "firewall.$section.family" "ipv4"
}

ensure_vpnmode_config_file() {
  if [ ! -f /etc/config/vpnmode ]; then
    log "creating /etc/config/vpnmode"
    : > /etc/config/vpnmode
  fi
}

configure_awg_iface() {
  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  interface_blob="$(extract_section_blob "$conf" Interface)"
  peer_blob="$(extract_section_blob "$conf" Peer)"

  log "Configuring $iface from $(basename "$conf")"
  log "Parsed Interface blob: [$interface_blob]"
  log "Parsed Peer blob: [$peer_blob]"

  private_key="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" PrivateKey)"
  address="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" Address)"
  dns="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" DNS)"
  jc="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" Jc)"
  jmin="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" Jmin)"
  jmax="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" Jmax)"
  s1="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" S1)"
  s2="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" S2)"
  s3="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" S3)"
  s4="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" S4)"
  h1="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" H1)"
  h2="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" H2)"
  h3="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" H3)"
  h4="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" H4)"
  i1="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" I1)"
  i2="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" I2)"
  i3="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" I3)"
  i4="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" I4)"
  i5="$(get_blob_value "$interface_blob" "$INTERFACE_KEYS" I5)"

  public_key="$(get_blob_value "$peer_blob" "$PEER_KEYS" PublicKey)"
  preshared_key="$(get_blob_value "$peer_blob" "$PEER_KEYS" PresharedKey)"
  allowed_ips="$(get_blob_value "$peer_blob" "$PEER_KEYS" AllowedIPs)"
  endpoint="$(get_blob_value "$peer_blob" "$PEER_KEYS" Endpoint)"
  keepalive="$(get_blob_value "$peer_blob" "$PEER_KEYS" PersistentKeepalive)"

  endpoint_host="${endpoint%:*}"
  endpoint_port="${endpoint##*:}"
  [ "$endpoint_host" = "$endpoint" ] && endpoint_port=""

  uci_delete_if_exists "network.$iface"
  # delete any old peer sections referencing this interface
  for sec in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=amneziawg_.*$/\1/p'); do
    [ -n "$sec" ] || continue
    sec_iface="$(uci -q get network.$sec.interface || true)"
    [ "$sec_iface" = "$iface" ] && {
      log "uci delete network.$sec"
      uci -q delete "network.$sec" || true
    }
  done

  log "uci set network.$iface = [interface]"
  uci set "network.$iface=interface"
  uci_set_logged "network.$iface.proto" "amneziawg"
  uci_set_logged "network.$iface.private_key" "$private_key"

  for item in $(split_csv_to_lines "$address"); do
    uci_add_list_logged "network.$iface.addresses" "$item"
  done
  for item in $(split_csv_to_lines "$dns"); do
    uci_add_list_logged "network.$iface.dns" "$item"
  done

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

  peer_sec="$(uci_add_section_logged network "amneziawg_$iface")"
  uci_set_logged "network.$peer_sec.interface" "$iface"
  uci_set_logged "network.$peer_sec.public_key" "$public_key"
  uci_set_logged "network.$peer_sec.preshared_key" "$preshared_key"
  for item in $(split_csv_to_lines "$allowed_ips"); do
    uci_add_list_logged "network.$peer_sec.allowed_ips" "$item"
  done
  uci_set_logged "network.$peer_sec.endpoint_host" "$endpoint_host"
  uci_set_logged "network.$peer_sec.endpoint_port" "$endpoint_port"
  uci_set_logged "network.$peer_sec.persistent_keepalive" "$keepalive"

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
    vpn-mode-install.sh)
      ensure_vpnmode_config_file
      sh "$file" || {
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

need_cmd uci
need_cmd sed
need_cmd grep
need_cmd cut
need_cmd tr
need_cmd dirname
need_cmd cat

need_file "$VENDOR_DIR/amneziawg-install.sh"
need_file "$VENDOR_DIR/vpn-mode-install.sh"

if [ ! -f "$AWG0_CONF" ] && [ ! -f "$AWG1_CONF" ]; then
  echo "ERROR: neither ./awg0.conf nor ./awg1.conf was found in current directory: $WORKDIR" >&2
  exit 1
fi

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
uci commit vpnmode || true

/etc/init.d/network reload || /etc/init.d/network restart || true
/etc/init.d/firewall restart || true
/etc/init.d/dnsmasq restart || true

if [ -x /etc/init.d/getdomains ]; then
  /etc/init.d/getdomains enable || true
fi

if [ -x /usr/bin/vpn-mode-apply ]; then
  /usr/bin/vpn-mode-apply || true
fi

log "Done"
