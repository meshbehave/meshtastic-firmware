#!/usr/bin/env bash
# Build meshtasticd natively on a remote armhf host (SSH from an arm64 runner).
#
# Required env:
#   ARMHF_BUILD_HOST  SSH destination (Host alias or user@host). Not hardcoded —
#                     set via GitHub Actions repository variable / runner env.
#
# Optional env:
#   ARMHF_REMOTE_DIR  Remote workdir relative to remote $HOME (default: ci/meshtastic-firmware)
#
# Expects: cwd is a checked-out firmware tree (submodules already populated).
# Produces: ./meshtasticd-armhf in the local cwd.
set -euo pipefail

HOST="${ARMHF_BUILD_HOST:-}"
if [[ -z "$HOST" ]]; then
  echo "::error::ARMHF_BUILD_HOST is not set (use a repository variable / secret, not a hardcoded hostname in YAML)"
  exit 1
fi

REMOTE_DIR="${ARMHF_REMOTE_DIR:-ci/meshtastic-firmware}"
# normalize: no leading slash, no trailing slash
REMOTE_DIR="${REMOTE_DIR#/}"
REMOTE_DIR="${REMOTE_DIR%/}"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)
RSYNC=(
  rsync -a --delete
  --exclude '.git/'
  --exclude '.pio/'
  --exclude '.venv/'
  --exclude 'meshtasticd-armhf'
  --exclude 'meshtasticd-arm64'
)

echo "==> Preflight: SSH reachable and host is armhf (32-bit)"
"${SSH[@]}" "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
arch=$(uname -m)
dpkg_arch=$(dpkg --print-architecture 2>/dev/null || echo unknown)
long_bit=$(getconf LONG_BIT)
machine=$(gcc -dumpmachine 2>/dev/null || echo unknown)

echo "host=$(hostname)"
echo "uname -m=$arch"
echo "dpkg --print-architecture=$dpkg_arch"
echo "getconf LONG_BIT=$long_bit"
echo "gcc -dumpmachine=$machine"
echo "uname -a=$(uname -a)"

case "$arch" in
  armv6l|armv7l) ;;
  *)
    echo "::error::Expected uname -m armv6l/armv7l (armhf build host), got: $arch"
    exit 1
    ;;
esac

if [[ "$dpkg_arch" != "armhf" ]]; then
  echo "::error::Expected dpkg architecture armhf, got: $dpkg_arch"
  exit 1
fi

if [[ "$long_bit" != "32" ]]; then
  echo "::error::Expected 32-bit userspace (getconf LONG_BIT=32), got: $long_bit"
  exit 1
fi

case "$machine" in
  arm-linux-gnueabihf|arm-linux-gnueabi) ;;
  *)
    echo "::error::Unexpected gcc triple (want arm-linux-gnueabihf): $machine"
    exit 1
    ;;
esac

echo "PREFLIGHT_OK: remote host is armhf"
REMOTE

echo "==> Sync sources -> ${HOST}:${REMOTE_DIR}/"
# shellcheck disable=SC2086
"${RSYNC[@]}" ./ "${HOST}:${REMOTE_DIR}/"

echo "==> Native armhf build on remote (venv + pio on disk, not /tmp tmpfs)"
"${SSH[@]}" "$HOST" "REMOTE_DIR=$(printf %q "$REMOTE_DIR") bash -s" <<'REMOTE'
set -euo pipefail
cd "$HOME/$REMOTE_DIR"

# Disk-backed paths — /tmp is often a small tmpfs on Pi hosts
BUILD_ROOT="${HOME}/ci"
VENV="${BUILD_ROOT}/venvs/pio-meshtasticd-$$"
OUT="${BUILD_ROOT}/meshtasticd-armhf"
mkdir -p "${BUILD_ROOT}/venvs"

cleanup() {
  rm -rf "$VENV"
}
trap cleanup EXIT

sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libbluetooth-dev libgpiod-dev libyaml-cpp-dev \
  libjsoncpp-dev libssl-dev libulfius-dev liborcania-dev \
  libusb-1.0-0-dev libi2c-dev libuv1-dev \
  python3-venv python3-pip pkg-config g++

python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -U pip
"$VENV/bin/pip" install -q platformio

# Avoid inheriting odd SSL/lib path quirks from the agent environment
export LD_LIBRARY_PATH=""

"$VENV/bin/pio" run -e native

src=".pio/build/native/meshtasticd"
if [[ ! -f "$src" ]]; then
  echo "::error::Expected binary missing: $src"
  exit 1
fi
cp -f "$src" "$OUT"
chmod +x "$OUT"

echo "==> Remote binary verification"
file "$OUT"
if command -v readelf >/dev/null 2>&1; then
  readelf -h "$OUT" | grep -E 'Class:|Machine:|OS/ABI:'
fi
# Must be ELF 32-bit ARM
file "$OUT" | grep -Eiq 'ELF 32-bit.*(ARM|arm)' || {
  echo "::error::Binary is not ELF 32-bit ARM: $(file "$OUT")"
  exit 1
}
echo "REMOTE_BUILD_OK: $OUT"
REMOTE

echo "==> Fetch binary"
"${SCP[@]}" "${HOST}:ci/meshtasticd-armhf" ./meshtasticd-armhf
chmod +x ./meshtasticd-armhf

echo "==> Local artifact check"
file ./meshtasticd-armhf
ls -lh ./meshtasticd-armhf
echo "DONE: meshtasticd-armhf"
