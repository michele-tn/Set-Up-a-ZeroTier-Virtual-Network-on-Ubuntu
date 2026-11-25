#!/usr/bin/env bash
# Static-review revision: Ubuntu 22.04, systemd, endpoint membership only.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
umask 077

readonly INSTALLER_URL='https://install.zerotier.com'
readonly TOTAL=6
STEP=0
DRY_RUN=0
VERBOSE=0
COLOR=1
EXPECTED_SHA256=''
NETWORK_ID=''
WORK_DIR=''
LOG=''
RST='' GRN='' CYN='' YEL=''

usage() {
  cat <<'HELP'
Usage: sudo bash install-zerotier-demoscene.improved.sh [OPTIONS] NETWORK_ID
  --installer-sha256 HEX  SHA-256 of independently reviewed installer bytes.
                         Required only when ZeroTier must be installed.
  --dry-run              Print the plan; no writes, downloads or daemon calls.
  --verbose              Show executable names, never arguments or command output.
  --no-color             Disable terminal colours and animations (also NO_COLOR).
  --help                 Show this help without root or filesystem changes.
Target: Ubuntu 22.04 with systemd as PID 1. Other releases fail closed.
Exit: 0 join submitted (authorization may be pending), 1 local failure,
      2 reported network failure, 130 interrupted, 143 terminated.
No firewall, forwarding, existing memberships or automatic authorization changes.
The reviewed installer and its dependencies still run with root privileges.
HELP
}

fail() { printf '[FAIL] %s\n' "$1" >&2; exit "${2:-1}"; }
warn() { printf '[WARN] %s\n' "$1" >&2; }
ok() { printf '%s[ OK ]%s %s\n' "$GRN" "$RST" "$1"; }
step() {
  STEP=$((STEP + 1))
  printf '\n%s[%02d/%02d]%s %s\n' "$CYN" "$STEP" "$TOTAL" "$RST" "$1"
}

while (( $# )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --no-color) COLOR=0; shift ;;
    --installer-sha256)
      (( $# >= 2 )) || fail 'Missing SHA-256 value.'
      EXPECTED_SHA256=${2,,}
      [[ $EXPECTED_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail 'SHA-256 must be 64 hexadecimal characters.'
      shift 2 ;;
    --*) fail 'Unknown option; use --help.' ;;
    *)
      [[ -z $NETWORK_ID ]] || fail 'Exactly one network ID is required.'
      NETWORK_ID=${1,,}
      shift ;;
  esac
done
[[ $NETWORK_ID =~ ^[0-9a-f]{16}$ ]] || fail 'Network ID must be 16 hexadecimal characters; use --help.'
readonly NETWORK_ID EXPECTED_SHA256

if (( DRY_RUN )); then
  cat <<'PLAN'
DRY RUN: plan only; OS, privilege, package and network state are NOT validated.
1. Require root, Ubuntu 22.04, systemd and the required commands; acquire lock.
2. If CLI/package/unit are absent: require reviewed SHA-256, update APT, install tools.
3. Download installer over HTTPS with bounded connection and transfer time.
4. Compare SHA-256 before running installer as root; abort on mismatch.
5. Enable/start zerotier-one and poll local CLI (each call bounded).
6. Submit join, inspect JSON status; report pending authorization separately.
No changes have been made. Installer side effects are NOT simulated.
PLAN
  exit 0
fi

[[ $EUID -eq 0 ]] || fail 'Root required. Run with sudo; network ID omitted from this diagnostic.'
[[ -r /etc/os-release ]] || fail 'Cannot read /etc/os-release.'
# This is a root-controlled operating-system file on the supported target.
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || fail 'Supported target is Ubuntu 22.04 only.'
[[ -d /run/systemd/system ]] || fail 'A running systemd system instance is required.'

for tool in apt-get dpkg-query systemctl timeout flock mktemp chmod rm bash awk sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing prerequisite: $tool"
done

NEEDS_INSTALL=1
if command -v zerotier-cli >/dev/null 2>&1; then
  [[ $(dpkg-query -W -f='${Status}' zerotier-one 2>/dev/null) == 'install ok installed' ]] \
    || fail 'CLI exists without an installed zerotier-one Debian package; reconcile manually.'
  systemctl cat zerotier-one.service >/dev/null 2>&1 \
    || fail 'CLI exists but the zerotier-one systemd unit is missing.'
  command -v python3 >/dev/null 2>&1 || fail 'Existing installation needs python3 for status parsing.'
  NEEDS_INSTALL=0
else
  [[ -n $EXPECTED_SHA256 ]] || fail 'Fresh installation requires --installer-sha256 from independently reviewed bytes.'
fi

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n $WORK_DIR ]]; then
    rm -f -- "$WORK_DIR/installer.sh" || true
    printf 'Private diagnostic log retained: %s\n' "$LOG" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'rc=$?; printf "[FAIL] Line %s, exit %s; inspect the private log.\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

# /run is root-controlled on the supported target; kernel releases lock on exit.
exec 9>/run/zerotier-demoscene.lock
flock -n 9 || fail 'Another installer is running.'
WORK_DIR=$(mktemp -d /tmp/zerotier-demoscene.XXXXXXXX)
chmod 700 "$WORK_DIR"
LOG="$WORK_DIR/install.log"
: >"$LOG"
chmod 600 "$LOG"
# Private artifacts already have explicit modes; let package/vendor subprocesses
# create ordinary system configuration with conventional installation permissions.
umask 022

if [[ -t 1 && -z ${NO_COLOR+x} && $COLOR -eq 1 && ${TERM:-dumb} != dumb ]]; then
  RST=$'\033[0m' GRN=$'\033[1;32m' CYN=$'\033[1;36m' YEL=$'\033[1;33m'
fi

copper() {
  local color
  if [[ -z $RST ]]; then
    printf '%s\n' '  ::::::::::::::::::::::::::::::::::::::::::::::::::::'
    return 0
  fi
  for color in 196 208 220 190 82 47 49 45 33 21 129 201; do
    printf '\033[48;5;%dm  %s' "$color" "$RST"
    sleep 0.02
  done
  printf '\n'
}

run() {
  local label=$1 rc
  shift
  if (( VERBOSE )); then printf '[RUN] %s (arguments hidden)\n' "$1"; fi
  # Foreground execution avoids an orphaned spinner worker; no raw log in stdout.
  if "$@" >>"$LOG" 2>&1; then
    ok "$label"
  else
    rc=$?
    fail "$label; command exit $rc. Inspect the private log." "$rc"
  fi
}

wait_ready() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if timeout 2s zerotier-cli info >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

copper
printf '%sZEROTIER // DEMOSCENE INSTALLER%s\n' "$GRN" "$RST"
step 'Checking parameters, privileges and system'
ok 'Ubuntu 22.04, root, systemd; network ID accepted (hidden)'
warn 'NEEDRESTART_MODE=a permits dependency installation to restart affected services.'

step 'Preparing dependencies'
if (( NEEDS_INSTALL )); then
  run 'Updating package index' apt-get update -qq
  run 'Installing dependencies' apt-get install -y -qq curl gnupg ca-certificates python3
else
  ok 'Existing Debian package and service unit found; installation steps skipped'
fi

step 'Fetching the official installer'
if (( NEEDS_INSTALL )); then
  run 'Downloading installer over HTTPS' curl --proto '=https' --proto-redir '=https' \
    -fsSL --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 2 \
    --retry-max-time 240 "$INSTALLER_URL" -o "$WORK_DIR/installer.sh"
  [[ -s $WORK_DIR/installer.sh ]] || fail 'Downloaded installer is empty.'
  ACTUAL_SHA256=$(sha256sum "$WORK_DIR/installer.sh")
  ACTUAL_SHA256=${ACTUAL_SHA256%% *}
  [[ $ACTUAL_SHA256 == "$EXPECTED_SHA256" ]] || fail 'Installer SHA-256 mismatch; nothing downloaded will be executed.'
  ok 'Installer bytes match the independently supplied SHA-256'
else
  ok 'No download required'
fi

step 'Installing ZeroTier One'
if (( NEEDS_INSTALL )); then
  run 'Running reviewed installer as root' bash "$WORK_DIR/installer.sh"
  command -v zerotier-cli >/dev/null 2>&1 || fail 'Installer returned without zerotier-cli.'
  [[ $(dpkg-query -W -f='${Status}' zerotier-one 2>/dev/null) == 'install ok installed' ]] \
    || fail 'Installer returned without an installed zerotier-one Debian package.'
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required for status parsing.'
else
  ok 'Existing ZeroTier installation preserved'
fi

step 'Starting the zerotier-one service'
run 'Enabling and starting service' systemctl enable --now zerotier-one
run 'Waiting for local daemon (at most 30 bounded attempts)' wait_ready

step 'Submitting network join (network ID hidden)'
run 'Sending join request' timeout 15s zerotier-cli join "$NETWORK_ID"
# JSON avoids column assumptions when network names contain whitespace.
NETWORK_STATE=$(timeout 15s zerotier-cli -j listnetworks | python3 -c '
import json, sys
networks = json.load(sys.stdin)
if not isinstance(networks, list):
    raise SystemExit("Expected network list")
matches = [n for n in networks if isinstance(n, dict) and n.get("id") == sys.argv[1]]
state = matches[0].get("status") if len(matches) == 1 else "NOT_LISTED"
allowed = {"OK", "ACCESS_DENIED", "REQUESTING_CONFIGURATION", "NOT_FOUND", "PORT_ERROR", "CLIENT_TOO_OLD", "NOT_LISTED"}
print(state if isinstance(state, str) and state in allowed else "UNKNOWN")
' "$NETWORK_ID")

printf '\n%sJOIN REQUEST SUBMITTED%s\nNetwork status: %s\n' "$YEL" "$RST" "$NETWORK_STATE"
case "$NETWORK_STATE" in
  OK) ok 'Controller reports OK; application reachability still needs a separate check.' ;;
  ACCESS_DENIED|REQUESTING_CONFIGURATION|NOT_LISTED)
    warn 'Membership is pending. Authorize this device in your trusted ZeroTier Central account and recheck.' ;;
  NOT_FOUND|PORT_ERROR|CLIENT_TOO_OLD|UNKNOWN)
    fail 'Join was submitted, but network state requires investigation; no rollback was attempted.' 2 ;;
esac
printf '%s\n' 'Inspect locally: sudo zerotier-cli info; sudo zerotier-cli listnetworks'
printf '%s\n' 'Firewall and IP forwarding were not changed by this wrapper.'
copper
