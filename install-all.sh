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

is_known_key() {
  case "$1" in
    PrivateKey|Address|DNS|PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive|Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4|S3|S4|I1|I2|I3|I4|I5)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_section_token() {
  case "$1" in
    "[Interface]"|"[Peer]")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

trim_spaces() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

append_value_token() {
  current="$1"
  token="$2"
  if [ -z "$current" ]; then
    printf '%s' "$token"
  else
    printf '%s %s' "$current" "$token"
  fi
}

parse_conf_value() {
  file="$1"
  section="$2"
  key="$3"

  content="$(tr '\r\n' '  ' < "$file")"
  set -- $content
  current_section=""

  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift

    case "$tok" in
      "[Interface]"|"[Peer]")
        current_section="${tok#[}"
        current_section="${current_section%]}"
        continue
        ;;
    esac

    [ "$current_section" = "$section" ] || continue

    if [ "$tok" = "$key" ] && [ "${1-}" = "=" ]; then
      shift
      value=""
      while [ "$#" -gt 0 ]; do
        if is_section_token "$1"; then
          break
        fi

        if is_known_key "$1" && [ "${2-}" = "=" ]; then
          break
        fi

        case "$1" in
          *=*)
            maybe_key="${1%%=*}"
            if is_known_key "$maybe_key"; then
              break
            fi
            ;;
        esac

        value="$(append_value_token "$value" "$1")"
        shift
      done
      trim_spaces "$value"
      return 0
    fi

    case "$tok" in
      "$key"=*)
        value="${tok#*=}"
        while [ "$#" -gt 0 ]; do
          if is_section_token "$1"; then
            break
          fi

          if is_known_key "$1" && [ "${2-}" = "=" ]; then
            break
          fi

          case "$1" in
            *=*)
              maybe_key="${1%%=*}"
              if is_known_key "$maybe_key"; then
                break
              fi
              ;;
          esac

          value="$(append_value_token "$value" "$1")"
          shift
        done
        trim_spaces "$value"
        return 0
        ;;
    esac
  done

  return 0
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

uci_replace_list() {
  key="$1"
  value="$2"
  [ -n "$value" ] || return 0
  uci -q delete "$key" || true
  OLD_IFS="$IFS"
  IFS=','
  set -- $value
  IFS="$OLD_IFS"
  for item in "$@"; do
    item="$(trim_spaces "$item")"
    [ -n "$item" ] || continue
    uci add_list "$key=$item"
  done
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

create_peer_section() {
  iface="$1"
  section_name="${iface}_peer"

  uci_delete_if_exists "network.$section_name"
  uci set "network.$section_name=amneziawg_${iface}"
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
  uci_replace_list "network.$iface.addresses" "$address"
  uci_replace_list "network.$iface.dns" "$dns"

  uci_set_opt "network.$iface.jc" "$jc"
  uci_set_opt "network.$iface.jmin" "$jmin"
  uci_set_opt "network.$iface.jmax" "$jmax"
  uci_set_opt "network.$iface.s1" "$s1"
  uci_set_opt "network.$iface.s2" "$s2"
  uci_set_opt "network.$iface.h1" "$h1"
  uci_set_opt "network.$iface.h2" "$h2"
  uci_set_opt "network.$iface.h3" "$h3"
  uci_set_opt "network.$iface.h4" "$h4"
  uci_set_opt "network.$iface.s3" "$s3"
  uci_set_opt "network.$iface.s4" "$s4"
  uci_set_opt "network.$iface.i1" "$i1"
  uci_set_opt "network.$iface.i2" "$i2"
  uci_set_opt "network.$iface.i3" "$i3"
  uci_set_opt "network.$iface.i4" "$i4"
  uci_set_opt "network.$iface.i5" "$i5"

  create_peer_section "$iface"
  uci_set_opt "network.${iface}_peer.public_key" "$public_key"
  uci_set_opt "network.${iface}_peer.preshared_key" "$preshared_key"
  uci_replace_list "network.${iface}_peer.allowed_ips" "$allowed_ips"
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
