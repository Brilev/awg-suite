#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKDIR="${AWG_WORKDIR:-$PWD}"
VENDOR_DIR="$REPO_DIR/vendor"

AWG0_CONF="$WORKDIR/awg0.conf"
AWG1_CONF="$WORKDIR/awg1.conf"

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

need_file() {
  [ -f "$1" ] || fail "required file not found: $1"
}

need_cmd uci
need_cmd sed
need_cmd grep
need_cmd cut
need_cmd tr
need_cmd dirname
need_cmd basename

need_file "$VENDOR_DIR/amneziawg-install.sh"
need_file "$VENDOR_DIR/vpn-mode-install.sh"

if [ ! -f "$AWG0_CONF" ] && [ ! -f "$AWG1_CONF" ]; then
  fail "neither ./awg0.conf nor ./awg1.conf was found in current directory: $WORKDIR"
fi

trim() {
  val="$1"
  # shellcheck disable=SC2001
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$val"
}

normalize_conf() {
  file="$1"
  content="$(tr '\r\n' '  ' < "$file")"
  content="$(printf '%s' "$content" | sed 's/\[/\n[/g')"
  content="$(printf '%s' "$content" | sed 's/[[:space:]][[:space:]]*/ /g')"
  printf '%s\n' "$content"
}

section_blob() {
  file="$1"
  section="$2"
  normalized="$(normalize_conf "$file")"
  current=""
  blob=""
  while IFS= read -r line; do
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    case "$line" in
      "[$section]"*)
        current="$section"
        line="${line#"[$section]"}"
        line="$(trim "$line")"
        [ -n "$line" ] && blob="$blob $line"
        ;;
      \[*\])
        current=""
        ;;
      *)
        [ "$current" = "$section" ] && blob="$blob $line"
        ;;
    esac
  done <<EOFSEC
$normalized
EOFSEC
  printf '%s' "$(trim "$blob")"
}

extract_key_from_blob() {
  blob="$1"
  key="$2"
  rest="$blob"

  while [ -n "$rest" ]; do
    case "$rest" in
      "$key = "*)
        value="${rest#"$key = "}"
        next_cut="$value"
        for marker in \
          ' PrivateKey = ' ' Address = ' ' DNS = ' ' MTU = ' \
          ' PublicKey = ' ' PresharedKey = ' ' AllowedIPs = ' ' Endpoint = ' \
          ' PersistentKeepalive = ' ' Jc = ' ' Jmin = ' ' Jmax = ' \
          ' S1 = ' ' S2 = ' ' H1 = ' ' H2 = ' ' H3 = ' ' H4 = ' \
          ' S3 = ' ' S4 = ' ' I1 = ' ' I2 = ' ' I3 = ' ' I4 = ' ' I5 = '
        do
          case "$next_cut" in
            *"$marker"*)
              next_cut="${next_cut%%$marker*}"
              ;;
          esac
        done
        printf '%s' "$(trim "$next_cut")"
        return 0
        ;;
      *" $key = "*)
        rest="${rest#*" $key = "}"
        rest="$key = $rest"
        ;;
      *)
        break
        ;;
    esac
  done

  return 1
}

parse_conf_value() {
  file="$1"
  section="$2"
  key="$3"
  blob="$(section_blob "$file" "$section")"
  [ -n "$blob" ] || return 0
  extract_key_from_blob "$blob" "$key" || true
}

split_csv_to_list() {
  value="$1"
  printf '%s' "$value" | tr ',' '\n' | while IFS= read -r item; do
    item="$(trim "$item")"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
}

split_space_or_csv_to_list() {
  value="$1"
  printf '%s' "$value" | tr ',' ' ' | tr ' ' '\n' | while IFS= read -r item; do
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

log_value() {
  key="$1"
  value="$2"
  if [ -z "$value" ]; then
    log "uci $key = <empty>"
  else
    log "uci $key = [$value]"
  fi
}

uci_set_logged() {
  key="$1"
  value="$2"
  log_value "$key" "$value"
  if ! uci set "$key=$value"; then
    warn "failed: uci set $key=[${value}]"
    exit 1
  fi
}

uci_add_list_logged() {
  key="$1"
  value="$2"
  log_value "$key (+list)" "$value"
  if ! uci add_list "$key=$value"; then
    warn "failed: uci add_list $key=[${value}]"
    exit 1
  fi
}

find_zone_sections_by_name() {
  zone_name="$1"
  uci show firewall 2>/dev/null \
    | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p" \
    | while IFS= read -r sec; do
        [ -n "$sec" ] || continue
        name="$(uci -q get firewall."$sec".name || true)"
        [ "$name" = "$zone_name" ] && echo "$sec"
      done
}

find_zone_sections_by_network() {
  net="$1"
  uci show firewall 2>/dev/null \
    | sed -n "s/^firewall\.\([^.=]*\)=zone$/\1/p" \
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
    log "Removing duplicate firewall zone: $sec"
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

create_peer_section() {
  iface="$1"
  peer_name="${iface}_peer"
  existing_type="$(uci -q show network | sed -n "s/^network\.$peer_name=\(.*\)$/\1/p" | head -n1 || true)"

  if [ -n "$existing_type" ]; then
    log "Existing peer section network.$peer_name type=$existing_type"
    uci -q delete "network.$peer_name"
  fi

  uci_set_logged "network.$peer_name" "amneziawg_${iface}"
}

configure_awg_iface() {
  iface="$1"
  conf="$2"

  [ -f "$conf" ] || return 0

  private_key="$(parse_conf_value "$conf" Interface PrivateKey)"
  address="$(parse_conf_value "$conf" Interface Address)"
  dns="$(parse_conf_value "$conf" Interface DNS)"
  mtu="$(parse_conf_value "$conf" Interface MTU)"
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
  log "Parsed Interface blob: [$(section_blob "$conf" Interface)]"
  log "Parsed Peer blob: [$(section_blob "$conf" Peer)]"

  uci_delete_if_exists "network.$iface"
  uci_delete_if_exists "network.${iface}_peer"

  uci_set_logged "network.$iface" "interface"
  uci_set_logged "network.$iface.proto" "amneziawg"

  [ -n "$private_key" ] && uci_set_logged "network.$iface.private_key" "$private_key"
  [ -n "$mtu" ] && uci_set_logged "network.$iface.mtu" "$mtu"

  if [ -n "$address" ]; then
    for item in $(split_csv_to_list "$address"); do
      uci_add_list_logged "network.$iface.addresses" "$item"
    done
  fi

  if [ -n "$dns" ]; then
    for item in $(split_space_or_csv_to_list "$dns"); do
      uci_add_list_logged "network.$iface.dns" "$item"
    done
  fi

  [ -n "$jc" ] && uci_set_logged "network.$iface.jc" "$jc"
  [ -n "$jmin" ] && uci_set_logged "network.$iface.jmin" "$jmin"
  [ -n "$jmax" ] && uci_set_logged "network.$iface.jmax" "$jmax"
  [ -n "$s1" ] && uci_set_logged "network.$iface.s1" "$s1"
  [ -n "$s2" ] && uci_set_logged "network.$iface.s2" "$s2"
  [ -n "$h1" ] && uci_set_logged "network.$iface.h1" "$h1"
  [ -n "$h2" ] && uci_set_logged "network.$iface.h2" "$h2"
  [ -n "$h3" ] && uci_set_logged "network.$iface.h3" "$h3"
  [ -n "$h4" ] && uci_set_logged "network.$iface.h4" "$h4"
  [ -n "$s3" ] && uci_set_logged "network.$iface.s3" "$s3"
  [ -n "$s4" ] && uci_set_logged "network.$iface.s4" "$s4"
  [ -n "$i1" ] && uci_set_logged "network.$iface.i1" "$i1"
  [ -n "$i2" ] && uci_set_logged "network.$iface.i2" "$i2"
  [ -n "$i3" ] && uci_set_logged "network.$iface.i3" "$i3"
  [ -n "$i4" ] && uci_set_logged "network.$iface.i4" "$i4"
  [ -n "$i5" ] && uci_set_logged "network.$iface.i5" "$i5"

  create_peer_section "$iface"
  [ -n "$public_key" ] && uci_set_logged "network.${iface}_peer.public_key" "$public_key"
  [ -n "$preshared_key" ] && uci_set_logged "network.${iface}_peer.preshared_key" "$preshared_key"

  if [ -n "$allowed_ips" ]; then
    for item in $(split_csv_to_list "$allowed_ips"); do
      uci_add_list_logged "network.${iface}_peer.allowed_ips" "$item"
    done
  fi

  [ -n "$endpoint_host" ] && uci_set_logged "network.${iface}_peer.endpoint_host" "$endpoint_host"
  [ -n "$endpoint_port" ] && uci_set_logged "network.${iface}_peer.endpoint_port" "$endpoint_port"
  [ -n "$keepalive" ] && uci_set_logged "network.${iface}_peer.persistent_keepalive" "$keepalive"

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
