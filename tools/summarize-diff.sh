#!/bin/sh
set -eu
REPORT_DIR="${1:-}"
[ -n "$REPORT_DIR" ] || { echo "Usage: sh tools/summarize-diff.sh reports/<timestamp>"; exit 1; }
[ -d "$REPORT_DIR" ] || { echo "Report dir not found: $REPORT_DIR" >&2; exit 1; }
echo "Нужно обновить awg-bootstrap."
echo
echo "Сводка по upstream:"
awk '/^FILE:/ {file=$2} /^UPSTREAM_URL:/ {url=$2} /^STATUS:/ {print "- " file ": " $2 "\n  upstream: " url}' "$REPORT_DIR/summary.txt"
echo
echo "Изменённые файлы:"
for f in "$REPORT_DIR"/*.diff; do [ -f "$f" ] || continue; name="$(basename "$f" .diff)"; plus="$(grep -c '^[+][^+]' "$f" || true)"; minus="$(grep -c '^[-][^-]' "$f" || true)"; echo "- $name: +$plus / -$minus"; done
