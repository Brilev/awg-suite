#!/bin/sh
set -eu

: "${AWG_BOOTSTRAP_REPO:=Brilev/awg-suite}"
: "${AWG_BOOTSTRAP_REF:=main}"

WORK_DIR="$(pwd)"
TMP_DIR="$(mktemp -d /tmp/awg-bootstrap.XXXXXX)"
ARCHIVE_URL="https://codeload.github.com/${AWG_BOOTSTRAP_REPO}/tar.gz/${AWG_BOOTSTRAP_REF}"

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

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

need_cmd wget
need_cmd tar
need_cmd sh

log "working directory: $WORK_DIR"
log "downloading repo archive: $ARCHIVE_URL"

wget -q -O "$TMP_DIR/repo.tar.gz" "$ARCHIVE_URL" || fail "failed to download repo archive"
mkdir -p "$TMP_DIR/src"
tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR/src" || fail "failed to extract repo archive"

REPO_DIR="$(find "$TMP_DIR/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$REPO_DIR" ] || fail "repo directory not found after extraction"
[ -f "$REPO_DIR/install-all.sh" ] || fail "install-all.sh not found in extracted repo"

log "running install-all.sh from extracted repo"
cd "$WORK_DIR"
sh "$REPO_DIR/install-all.sh" "$@"
