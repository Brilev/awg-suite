#!/bin/sh
set -eu
REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor"
REPORTS_DIR="$REPO_ROOT/reports"
TMP_DIR="$(mktemp -d /tmp/awg-upstream-check.XXXXXX)"
DATE_TAG="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="$REPORTS_DIR/$DATE_TAG"
mkdir -p "$REPORT_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
fetch() { wget -q -O "$2" "$1"; [ -s "$2" ] || exit 1; }
normalize() { sed 's/\r$//' "$1" | sed 's/[[:space:]]\+$//' > "$2"; }
risk_scan() { { echo "Risk markers in $(basename "$1"):"; grep -nE '(^|[^a-zA-Z])(restart|reload|read[[:space:]]|uci[[:space:]]|opkg[[:space:]]|apk[[:space:]]|/etc/init\.d/|service[[:space:]])' "$1" || true; } > "$2"; }
process_one() {
  name="$1"; vendor_file="$2"; url="$3"
  upstream_raw="$TMP_DIR/$name.upstream.raw"; vendor_norm="$TMP_DIR/$name.vendor.norm"; upstream_norm="$TMP_DIR/$name.upstream.norm"
  fetch "$url" "$upstream_raw"; normalize "$vendor_file" "$vendor_norm"; normalize "$upstream_raw" "$upstream_norm"
  vendor_sha="$(sha256sum "$vendor_file" | awk '{print $1}')"; upstream_sha="$(sha256sum "$upstream_raw" | awk '{print $1}')"
  {
    echo "FILE: $name"; echo "VENDOR_FILE: $vendor_file"; echo "UPSTREAM_URL: $url"; echo "VENDOR_SHA256: $vendor_sha"; echo "UPSTREAM_SHA256: $upstream_sha";
    if [ "$vendor_sha" = "$upstream_sha" ]; then echo "STATUS: same"; else echo "STATUS: changed"; fi; echo;
  } >> "$REPORT_DIR/summary.txt"
  if ! diff -u "$vendor_norm" "$upstream_norm" > "$REPORT_DIR/$name.diff"; then :; else rm -f "$REPORT_DIR/$name.diff"; fi
  risk_scan "$upstream_raw" "$REPORT_DIR/$name.risk.txt"
  cp "$upstream_raw" "$REPORT_DIR/$name.upstream.sh"
}
: > "$REPORT_DIR/summary.txt"
process_one "amneziawg-install" "$VENDOR_DIR/amneziawg-install.sh" "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh"
process_one "getdomains-install" "$VENDOR_DIR/getdomains-install.sh" "https://raw.githubusercontent.com/Brilev/domain-routing-openwrt/master/getdomains-install.sh"
process_one "vpn-mode-install" "$VENDOR_DIR/vpn-mode-install.sh" "https://raw.githubusercontent.com/Brilev/awg-openwrt/switch-awg0-awg1/vpn-mode-install.sh"
cat "$REPORT_DIR/summary.txt" | tee "$REPORT_DIR/RESULT.txt"
echo "Report dir: $REPORT_DIR"
