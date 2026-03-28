#!/bin/sh
set -eu

AWG_BOOTSTRAP_REPO="${AWG_BOOTSTRAP_REPO:-Brilev/awg-suite}"
AWG_BOOTSTRAP_BRANCH="${AWG_BOOTSTRAP_BRANCH:-main}"
AWG_BOOTSTRAP_TMP="${AWG_BOOTSTRAP_TMP:-$(mktemp -d /tmp/awg-suite.XXXXXX)}"
AWG_WORKDIR="${AWG_WORKDIR:-$PWD}"

cleanup() {
  rm -rf "$AWG_BOOTSTRAP_TMP"
}
trap cleanup EXIT INT TERM

ARCHIVE_URL="https://github.com/${AWG_BOOTSTRAP_REPO}/archive/refs/heads/${AWG_BOOTSTRAP_BRANCH}.tar.gz"
ARCHIVE_FILE="$AWG_BOOTSTRAP_TMP/repo.tar.gz"

echo "==> Repo:   $AWG_BOOTSTRAP_REPO"
echo "==> Branch: $AWG_BOOTSTRAP_BRANCH"
echo "==> Workdir: $AWG_WORKDIR"
echo "==> Downloading repository archive..."

wget -O "$ARCHIVE_FILE" "$ARCHIVE_URL"
mkdir -p "$AWG_BOOTSTRAP_TMP/unpack"
tar -xzf "$ARCHIVE_FILE" -C "$AWG_BOOTSTRAP_TMP/unpack"

REPO_DIR="$AWG_BOOTSTRAP_TMP/unpack/$(basename "$AWG_BOOTSTRAP_REPO")-$AWG_BOOTSTRAP_BRANCH"
[ -d "$REPO_DIR" ] || {
  echo "ERROR: unpacked repository directory not found: $REPO_DIR" >&2
  exit 1
}

[ -f "$REPO_DIR/install-all.sh" ] || {
  echo "ERROR: install-all.sh not found in downloaded repository" >&2
  exit 1
}

chmod +x "$REPO_DIR/install-all.sh"

cd "$AWG_WORKDIR"
exec sh "$REPO_DIR/install-all.sh"
