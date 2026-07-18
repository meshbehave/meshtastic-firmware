#!/usr/bin/env bash
# upgrade-meshtasticd-sniffer.sh
#
# Upgrade (or first-install) the traceroute-sniffer patched meshtasticd binary
# on a Raspberry Pi / Linux host.
#
# IMPORTANT — procedure source of truth:
#   Always fetch THIS script and SNIFFER.md from the HEAD of branch
#   "traceroute-sniffer" on GitHub (do not keep a long-lived local copy of the
#   script as the driver — it will go stale). See SNIFFER.md § Upgrade.
#
#   Binaries are downloaded from GitHub *Releases* (tag-pinned), not built here.
#
# Usage (on the device, as a user with passwordless or interactive sudo):
#   curl -fsSL "$SCRIPT_URL" -o /tmp/upgrade-meshtasticd-sniffer.sh
#   bash /tmp/upgrade-meshtasticd-sniffer.sh --tag v2.7.26-sniffer-20260718 --yes
#   bash /tmp/upgrade-meshtasticd-sniffer.sh --dry-run
#   bash /tmp/upgrade-meshtasticd-sniffer.sh --rollback --yes
#
set -euo pipefail

REPO="${MESHTASTIC_SNIFFER_REPO:-meshbehave/meshtastic-firmware}"
BRANCH="${MESHTASTIC_SNIFFER_BRANCH:-traceroute-sniffer}"
API="https://api.github.com/repos/${REPO}"
RELEASES_URL="https://github.com/${REPO}/releases"
BINARY_PATH="${MESHTASTICD_PATH:-/usr/bin/meshtasticd}"
OFFICIAL_PATH="${MESHTASTICD_OFFICIAL_PATH:-/usr/bin/meshtasticd.official}"
SERVICE="${MESHTASTICD_SERVICE:-meshtasticd}"
WORKDIR="${TMPDIR:-/tmp}/meshtasticd-sniffer-upgrade-$$"
BACKUP_DIR="${MESHTASTICD_BACKUP_DIR:-/var/backups/meshtasticd-sniffer}"

TAG=""
DRY_RUN=0
YES=0
ROLLBACK=0
FORCE_INSTALL=0
SKIP_LDD=0
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"

log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Upgrade the traceroute-sniffer meshtasticd binary from GitHub Releases.
Always re-fetch this script from branch HEAD before running (see SNIFFER.md).

Options:
  --tag TAG           Release tag (e.g. v2.7.26-sniffer-20260718).
                      Default: latest GitHub release for ${REPO}.
  --yes               Non-interactive apply (required to make changes).
  --dry-run           Precheck + download + verify only; no stop/install/start.
  --rollback          Restore the newest backup under ${BACKUP_DIR} (or .prev-*).
  --force-install     Allow first install when dpkg-divert is missing.
  --skip-ldd          Do not fail on ldd "not found" (not recommended).
  --binary-path PATH  Install path (default: ${BINARY_PATH}).
  --service NAME      systemd unit name without .service (default: ${SERVICE}).
  -h, --help          Show this help.

Examples:
  # Recommended: fetch latest script from branch HEAD, then run:
  SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/bin/upgrade-meshtasticd-sniffer.sh"
  curl -fsSL "\$SCRIPT_URL" -o /tmp/upgrade-meshtasticd-sniffer.sh
  bash /tmp/upgrade-meshtasticd-sniffer.sh --dry-run
  bash /tmp/upgrade-meshtasticd-sniffer.sh --tag v2.7.26-sniffer-20260718 --yes

Environment:
  MESHTASTIC_SNIFFER_REPO, MESHTASTIC_SNIFFER_BRANCH, MESHTASTICD_PATH,
  MESHTASTICD_SERVICE, MESHTASTICD_BACKUP_DIR, HEALTH_TIMEOUT_SEC
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

sudo_run() {
  if [[ "$(id -u)" -eq 0 ]]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) TAG="${2:-}"; shift 2 ;;
      --yes|-y) YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --rollback) ROLLBACK=1; shift ;;
      --force-install) FORCE_INSTALL=1; shift ;;
      --skip-ldd) SKIP_LDD=1; shift ;;
      --binary-path) BINARY_PATH="${2:-}"; shift 2 ;;
      --service) SERVICE="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done
}

detect_asset() {
  local arch
  if command -v dpkg >/dev/null 2>&1; then
    arch=$(dpkg --print-architecture)
  else
    case "$(uname -m)" in
      aarch64|arm64) arch=arm64 ;;
      armv7l|armv6l) arch=armhf ;;
      *) arch=unknown ;;
    esac
  fi
  case "$arch" in
    arm64|aarch64) echo "meshtasticd-arm64" ;;
    armhf) echo "meshtasticd-armhf" ;;
    *) die "unsupported architecture '$arch' (need arm64 or armhf)" ;;
  esac
}

resolve_tag() {
  if [[ -n "$TAG" ]]; then
    printf '%s\n' "$TAG"
    return
  fi
  info "Resolving latest release tag from GitHub…"
  need_cmd curl
  local json tag
  json=$(curl -fsSL "${API}/releases/latest")
  tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -n "$tag" ]] || die "could not resolve latest release tag for ${REPO}"
  printf '%s\n' "$tag"
}

release_asset_meta() {
  # Prints: digest_sha256  size  browser_download_url  (space-separated; digest may be empty)
  local tag="$1" asset="$2"
  local json
  json=$(curl -fsSL "${API}/releases/tags/${tag}")
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$json" | ASSET_NAME="$asset" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
want = os.environ["ASSET_NAME"]
for a in data.get("assets") or []:
    if a.get("name") == want:
        digest = a.get("digest") or ""
        if digest.startswith("sha256:"):
            digest = digest.split(":", 1)[1]
        else:
            digest = ""
        url = a.get("browser_download_url") or ""
        size = a.get("size") or 0
        print(f"{digest} {size} {url}")
        sys.exit(0)
sys.exit(1)
'; then
      return 0
    fi
  fi
  # Fallback: conventional URL, no digest
  printf ' 0 https://github.com/%s/releases/download/%s/%s\n' "$REPO" "$tag" "$asset"
}

precheck() {
  info "Precheck — host and install state"
  need_cmd curl
  need_cmd file
  need_cmd systemctl
  need_cmd install
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "required command not found: sha256sum or shasum"
  fi

  log "host=$(hostname 2>/dev/null || echo unknown)"
  log "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "uname=$(uname -a)"
  if command -v dpkg >/dev/null 2>&1; then
    log "dpkg_arch=$(dpkg --print-architecture)"
  fi
  log "long_bit=$(getconf LONG_BIT 2>/dev/null || echo unknown)"
  log "binary_path=${BINARY_PATH}"
  log "service=${SERVICE}"

  local avail_kb
  avail_kb=$(df -Pk / | awk 'NR==2{print $4}')
  log "root_free_kb=${avail_kb}"
  [[ "${avail_kb:-0}" -gt 102400 ]] || warn "low free disk on / (<100MB)"

  if [[ -x "$BINARY_PATH" ]]; then
    log "current_version=$( "$BINARY_PATH" --version 2>&1 | head -1 || true )"
    log "current_file=$(file "$BINARY_PATH" 2>/dev/null || true)"
  else
    warn "current binary missing or not executable: ${BINARY_PATH}"
  fi

  if command -v dpkg-divert >/dev/null 2>&1; then
    local divert
    divert=$(dpkg-divert --list "$BINARY_PATH" 2>/dev/null || true)
    if [[ -n "$divert" ]]; then
      log "dpkg_divert=present"
      log "  $divert"
    else
      log "dpkg_divert=absent"
      if [[ "$FORCE_INSTALL" -ne 1 && "$ROLLBACK" -ne 1 ]]; then
        die "dpkg-divert not set for ${BINARY_PATH}. First-time install: re-run with --force-install (see SNIFFER.md). Or fix divert manually."
      fi
    fi
  fi

  if systemctl cat "${SERVICE}.service" >/dev/null 2>&1; then
    log "systemd_unit=present"
    log "service_active=$(systemctl is-active "${SERVICE}" 2>/dev/null || true)"
  else
    warn "systemd unit ${SERVICE}.service not found — start/stop may fail"
  fi

  for p in /etc/meshtasticd /var/lib/meshtasticd; do
    if [[ -e "$p" ]]; then
      log "state_ok=${p}"
    else
      warn "missing path (may be fine on minimal installs): ${p}"
    fi
  done
}

download_and_verify() {
  local tag="$1" asset="$2"
  local digest size url newbin
  mkdir -p "$WORKDIR"
  newbin="${WORKDIR}/${asset}"

  info "Fetching release metadata for ${tag} / ${asset}"
  # shellcheck disable=SC2162
  read digest size url < <(release_asset_meta "$tag" "$asset") \
    || die "asset '${asset}' not found on release ${tag} (see ${RELEASES_URL}/tag/${tag})"

  [[ -n "$url" ]] || url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  info "Downloading ${url}"
  curl -fL --retry 3 --retry-delay 2 -o "$newbin" "$url"
  chmod +x "$newbin"

  local got_size
  got_size=$(wc -c <"$newbin" | tr -d ' ')
  if [[ -n "${size:-}" && "$size" != "0" && "$got_size" != "$size" ]]; then
    die "size mismatch for ${asset}: expected ${size}, got ${got_size}"
  fi

  if [[ -n "${digest:-}" ]]; then
    info "Verifying sha256 ${digest}"
    local got
    if command -v sha256sum >/dev/null 2>&1; then
      got=$(sha256sum "$newbin" | awk '{print $1}')
    else
      got=$(shasum -a 256 "$newbin" | awk '{print $1}')
    fi
    [[ "$got" == "$digest" ]] || die "sha256 mismatch: expected ${digest}, got ${got}"
    log "sha256_ok=${got}"
  else
    warn "no digest in release API — skipped sha256 verify"
    if command -v sha256sum >/dev/null 2>&1; then
      log "sha256=$(sha256sum "$newbin" | awk '{print $1}')"
    fi
  fi

  info "ELF / arch check"
  local ft
  ft=$(file "$newbin")
  log "file=${ft}"
  case "$asset" in
    meshtasticd-armhf)
      printf '%s' "$ft" | grep -Eiq 'ELF 32-bit.*(ARM|arm)' \
        || die "binary is not ELF 32-bit ARM: ${ft}"
      ;;
    meshtasticd-arm64)
      printf '%s' "$ft" | grep -Eiq 'ELF 64-bit.*(ARM|aarch64|arm64)' \
        || die "binary is not ELF 64-bit ARM: ${ft}"
      ;;
  esac

  if command -v ldd >/dev/null 2>&1; then
    info "Shared library check (ldd)"
    if ! ldd "$newbin" >"${WORKDIR}/ldd.txt" 2>&1; then
      # static or unusual — show output
      cat "${WORKDIR}/ldd.txt" || true
    else
      cat "${WORKDIR}/ldd.txt"
    fi
    if grep -q 'not found' "${WORKDIR}/ldd.txt" 2>/dev/null; then
      if [[ "$SKIP_LDD" -eq 1 ]]; then
        warn "ldd reported missing libraries (--skip-ldd set)"
      else
        die "ldd reported missing libraries (install deps or use --skip-ldd after review)"
      fi
    fi
  fi

  info "Smoke: --version"
  local ver
  ver=$("$newbin" --version 2>&1 | head -3 || true)
  [[ -n "$ver" ]] || die "new binary did not print --version"
  log "$ver"

  printf '%s\n' "$newbin"
}

ensure_backup_dir() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would mkdir -p ${BACKUP_DIR}"
    return
  fi
  sudo_run mkdir -p "$BACKUP_DIR"
}

backup_current() {
  ensure_backup_dir
  if [[ ! -e "$BINARY_PATH" ]]; then
    warn "no existing binary to backup at ${BINARY_PATH}"
    return 0
  fi
  local stamp dest
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dest="${BACKUP_DIR}/meshtasticd.prev-${stamp}"
  info "Backing up current binary -> ${dest}"
  sudo_run cp -a "$BINARY_PATH" "$dest"
  # keep a moving pointer for easy rollback
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would ln -sfn ${dest} ${BACKUP_DIR}/meshtasticd.prev"
  else
    sudo_run ln -sfn "$dest" "${BACKUP_DIR}/meshtasticd.prev"
  fi
  printf '%s\n' "$dest"
}

install_binary() {
  local newbin="$1"
  info "Installing ${newbin} -> ${BINARY_PATH}"
  sudo_run install -m 755 "$newbin" "$BINARY_PATH"
}

ensure_divert() {
  if ! command -v dpkg-divert >/dev/null 2>&1; then
    warn "dpkg-divert not available — skip package divert"
    return 0
  fi
  if dpkg-divert --list "$BINARY_PATH" 2>/dev/null | grep -q .; then
    log "dpkg_divert already configured"
    return 0
  fi
  info "Adding dpkg-divert for ${BINARY_PATH}"
  if [[ -e "$BINARY_PATH" && ! -e "$OFFICIAL_PATH" && "$FORCE_INSTALL" -eq 1 ]]; then
    # First install: preserve whatever is currently at BINARY_PATH as official if present before our install — usually we install after backup
    :
  fi
  # If official path empty but package owns binary, divert will rename on next package unpack.
  sudo_run dpkg-divert --add --no-rename --divert "$OFFICIAL_PATH" "$BINARY_PATH" \
    || warn "dpkg-divert add failed — continue but apt may overwrite the binary later"
}

stop_service() {
  info "Stopping ${SERVICE}"
  if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    sudo_run systemctl stop "$SERVICE"
  else
    log "service already inactive"
  fi
}

start_service() {
  info "Starting ${SERVICE}"
  sudo_run systemctl start "$SERVICE"
}

health_check() {
  info "Sanity / health check (timeout ${HEALTH_TIMEOUT_SEC}s)"
  local i
  for ((i = 1; i <= HEALTH_TIMEOUT_SEC; i++)); do
    if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
      log "service_active=yes (after ${i}s)"
      log "installed_version=$( "$BINARY_PATH" --version 2>&1 | head -1 || true )"
      systemctl --no-pager --full status "$SERVICE" 2>/dev/null | head -20 || true
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --full status "$SERVICE" 2>/dev/null | head -40 || true
  journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null || true
  return 1
}

do_rollback() {
  info "Rollback requested"
  local src=""
  if [[ -L "${BACKUP_DIR}/meshtasticd.prev" || -e "${BACKUP_DIR}/meshtasticd.prev" ]]; then
    src=$(readlink -f "${BACKUP_DIR}/meshtasticd.prev" 2>/dev/null || true)
  fi
  if [[ -z "$src" || ! -f "$src" ]]; then
    # pick newest meshtasticd.prev-* in backup dir
    src=$(ls -1t "${BACKUP_DIR}"/meshtasticd.prev-* 2>/dev/null | head -1 || true)
  fi
  # also consider co-located .prev next to binary (legacy)
  if [[ -z "$src" || ! -f "$src" ]]; then
    src=$(ls -1t "${BINARY_PATH}".prev-* 2>/dev/null | head -1 || true)
  fi
  [[ -n "$src" && -f "$src" ]] || die "no backup binary found under ${BACKUP_DIR} or ${BINARY_PATH}.prev-*"

  log "restore_from=${src}"
  if [[ "$YES" -ne 1 && "$DRY_RUN" -ne 1 ]]; then
    die "refusing rollback without --yes (or use --dry-run)"
  fi
  stop_service
  sudo_run install -m 755 "$src" "$BINARY_PATH"
  start_service
  health_check || die "rollback installed but service failed health check"
  info "Rollback complete"
}

confirm_apply() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if [[ "$YES" -ne 1 ]]; then
    die "refusing to modify the system without --yes (use --dry-run to preview)"
  fi
}

main_upgrade() {
  local tag asset newbin backup
  precheck
  tag=$(resolve_tag)
  asset=$(detect_asset)
  info "Target tag=${tag} asset=${asset}"
  newbin=$(download_and_verify "$tag" "$asset")

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "Dry-run complete — no changes made. Re-run with --tag ${tag} --yes to apply."
    return 0
  fi

  confirm_apply
  backup=$(backup_current || true)
  stop_service
  # On first install, if divert missing and --force-install, seed .official if a stock binary existed
  if [[ "$FORCE_INSTALL" -eq 1 ]] && command -v dpkg-divert >/dev/null 2>&1; then
    if ! dpkg-divert --list "$BINARY_PATH" 2>/dev/null | grep -q .; then
      if [[ -n "${backup:-}" && -f "$backup" && ! -e "$OFFICIAL_PATH" ]]; then
        info "Seeding ${OFFICIAL_PATH} from pre-upgrade backup for divert"
        sudo_run cp -a "$backup" "$OFFICIAL_PATH"
      fi
      ensure_divert
    fi
  fi
  install_binary "$newbin"
  ensure_divert

  if ! start_service || ! health_check; then
    warn "health check failed — attempting automatic rollback"
    if [[ -n "${backup:-}" && -f "$backup" ]]; then
      sudo_run install -m 755 "$backup" "$BINARY_PATH"
      start_service || true
      health_check || die "upgrade failed and rollback health check also failed — manual intervention required"
      die "upgrade failed; restored backup ${backup}"
    fi
    die "upgrade failed and no backup available"
  fi

  info "Upgrade successful"
  log "tag=${tag}"
  log "asset=${asset}"
  log "backup=${backup:-none}"
  log "binary=${BINARY_PATH}"
  log "version=$( "$BINARY_PATH" --version 2>&1 | head -1 || true )"
}

main() {
  parse_args "$@"
  info "upgrade-meshtasticd-sniffer.sh (fetch this file from ${REPO}@${BRANCH} HEAD each time)"
  log "repo=${REPO} branch=${BRANCH}"

  if [[ "$ROLLBACK" -eq 1 ]]; then
    precheck
    do_rollback
    exit 0
  fi

  main_upgrade
}

main "$@"
