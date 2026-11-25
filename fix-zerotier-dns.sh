#!/usr/bin/env bash
# Ubuntu 22.04 / systemd-resolved: diagnose, refresh, reversible runtime workaround.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
umask 077
readonly STATE_DIR=/run/zerotier-dns-fix
MODE=diagnose
MODE_SET=0
IFACE=''
DOMAIN=install.zerotier.com
DISABLE_DNSSEC=0
DISABLE_DOT=0
DRY_RUN=0
PENDING=0
TMP_STATE=''
STATE_FILE=''
OLD_DNSSEC=''
OLD_DOT=''
SAVED_DNSSEC=0
SAVED_DOT=0

usage() {
  cat <<'HELP'
Usage: bash fix-zerotier-dns.sh [MODE] [OPTIONS]
Modes (choose one; default: --diagnose):
  --diagnose     Read status, route, time and DNS results; no config changes.
  --refresh      Root: flush cache / learned server features, then recheck.
  --workaround   Root: explicit, temporary per-link security-policy workaround.
  --restore      Root: restore the effective policies saved by --workaround.
Options:
  --interface NAME   Required for workaround/restore; optional for diagnosis.
  --domain HOST      Test hostname (default: install.zerotier.com).
  --disable-dnssec   Workaround only: disable validation for the chosen link.
  --disable-dot      Workaround only: disable encrypted DNS for the chosen link.
  --dry-run          Print plan only, without host checks, queries or writes.
  --help             Print help.
Examples:
  bash fix-zerotier-dns.sh --diagnose
  sudo bash fix-zerotier-dns.sh --refresh
  sudo bash fix-zerotier-dns.sh --workaround --interface ens6 --disable-dnssec
  sudo bash fix-zerotier-dns.sh --restore --interface ens6
The workaround weakens DNS security for ALL queries on that link, not just HOST.
It does not edit resolv.conf/Netplan/drop-ins, change DNS servers/routes, restart
network services, install software, or download/execute the ZeroTier installer.
Restore promptly; runtime settings may be replaced by reboot/network management.
Restore pins saved EFFECTIVE values at runtime; original inheritance is not saved.
Exit 0: DNS + NSS lookup succeeded (or restore completed / plan printed).
Exit 1: prerequisites/command error; 2: lookup or recovery failure;
     3: diagnostic query works only with validation bypassed; 130/143: signals.
Diagnostic output includes local network metadata; redact before sharing.
HELP
}
fail() { printf '[FAIL] %s\n' "$1" >&2; exit "${2:-1}"; }
note() { printf '[INFO] %s\n' "$1"; }
set_mode() {
  (( MODE_SET == 0 )) || fail 'Choose exactly one mode.'
  MODE=$1
  MODE_SET=1
}
while (( $# )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --diagnose|--refresh|--workaround|--restore) set_mode "${1#--}"; shift ;;
    --interface|--domain)
      (( $# >= 2 )) || fail 'Missing option value.'
      if [[ $1 == --interface ]]; then IFACE=$2; else DOMAIN=${2,,}; fi
      shift 2 ;;
    --disable-dnssec) DISABLE_DNSSEC=1; shift ;;
    --disable-dot) DISABLE_DOT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) fail 'Unknown argument; use --help.' ;;
  esac
done
[[ -z $IFACE || $IFACE =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.:-]{0,14}$ ]] || fail 'Invalid interface name.'
[[ ${#DOMAIN} -le 253 && $DOMAIN != .* && $DOMAIN != *. && $DOMAIN != *..* ]] || fail 'Invalid DNS hostname.'
IFS=. read -r -a LABELS <<<"$DOMAIN"
for label in "${LABELS[@]}"; do
  [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail 'Invalid DNS hostname label.'
done
(( ${#LABELS[@]} >= 2 )) || fail 'Use a fully qualified DNS hostname.'
if [[ $MODE == workaround || $MODE == restore ]]; then
  [[ -n $IFACE ]] || fail 'Choose an explicit --interface; do not assume ens6.'
fi
if [[ $MODE == workaround ]]; then
  (( DISABLE_DNSSEC || DISABLE_DOT )) || fail 'Workaround requires an explicit --disable-dnssec and/or --disable-dot choice.'
else
  (( DISABLE_DNSSEC == 0 && DISABLE_DOT == 0 )) || fail 'Security-policy options require --workaround.'
fi
if (( DRY_RUN )); then
  printf 'PLAN ONLY: mode=%s, interface=%s, domain=%s\n' "$MODE" "${IFACE:-all}" "$DOMAIN"
  printf 'Disable DNSSEC=%s; disable DNS-over-TLS=%s\n' "$DISABLE_DNSSEC" "$DISABLE_DOT"
  note 'No host validation, queries, file writes or policy changes performed.'
  exit 0
fi

[[ -r /etc/os-release ]] || fail 'Cannot read operating-system identity.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 22.04 ]] || fail 'This helper targets Ubuntu 22.04 only.'
for tool in resolvectl systemctl timeout getent ip date cat; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done
systemctl is-active --quiet systemd-resolved || fail 'systemd-resolved must already be active; no service was started.'
if [[ -n $IFACE ]]; then
  [[ -r /sys/class/net/$IFACE/ifindex ]] || fail 'Selected interface does not exist.'
fi
QUERY_ARGS=(--no-pager --cache=no)
if [[ -n $IFACE ]]; then QUERY_ARGS+=(--interface="$IFACE"); fi

check_dns() {
  local failed=0
  if ! timeout 20s resolvectl "${QUERY_ARGS[@]}" query "$DOMAIN"; then failed=1; fi
  if ! timeout 15s getent ahosts "$DOMAIN"; then failed=1; fi
  return "$failed"
}

if [[ $MODE == diagnose ]]; then
  note 'Read-only diagnosis. Output may contain local addresses and DNS policy.'
  date -u
  ip route show default
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl show -p NTPSynchronized -p TimeUSec || true
  fi
  if [[ -n $IFACE ]]; then resolvectl --no-pager status "$IFACE"; else resolvectl --no-pager status; fi
  if check_dns; then
    note 'DNS and NSS resolution succeeded. This does not test HTTPS or authorization.'
    exit 0
  fi
  note 'Comparing one uncached query with DNSSEC validation disabled for that query only.'
  if timeout 20s resolvectl "${QUERY_ARGS[@]}" --validate=no query "$DOMAIN"; then
    note 'Bypassed query succeeded. Investigate validation/time/trust anchors/upstream; this is not proof of a root cause.'
    exit 3
  fi
  fail 'Resolution still fails. Check route, selected DNS server, firewall, proxy and resolver configuration.' 2
fi

[[ $EUID -eq 0 ]] || fail 'This mode requires root.'
for tool in flock install mktemp mv rm stat busctl; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing required command: $tool"
done
exec 9>/run/zerotier-dns-fix.lock
flock -n 9 || fail 'Another DNS helper instance is running.'
if [[ $MODE == refresh ]]; then
  timeout 15s resolvectl flush-caches
  timeout 15s resolvectl reset-server-features
  if check_dns; then note 'Resolution succeeded after cache/feature reset.'; exit 0; fi
  fail 'Refresh did not restore resolution; no security policies were disabled.' 2
fi

# /run is root-controlled on the supported host. Refuse unexpected existing state.
[[ ! -L $STATE_DIR ]] || fail 'Refusing a symlink for the state directory.'
if [[ -e $STATE_DIR ]]; then
  [[ -d $STATE_DIR && $(stat -c '%u:%a' "$STATE_DIR") == 0:700 ]] || fail 'State directory must be root-owned mode 0700.'
else
  install -d -m 700 "$STATE_DIR"
fi
STATE_FILE="$STATE_DIR/$IFACE.state"
INDEX=$(cat "/sys/class/net/$IFACE/ifindex")
MAC=$(cat "/sys/class/net/$IFACE/address")
DAEMON_PID=$(systemctl show -p MainPID --value systemd-resolved)
[[ $INDEX =~ ^[1-9][0-9]*$ && $DAEMON_PID =~ ^[1-9][0-9]*$ ]] || fail 'Cannot establish resolver/interface identity.'

read_policy() {
  local output
  output=$(timeout 10s busctl get-property org.freedesktop.resolve1 \
    "/org/freedesktop/resolve1/link/_$INDEX" org.freedesktop.resolve1.Link "$1") || return 1
  case "$output" in
    's "yes"') printf 'yes\n' ;;
    's "no"') printf 'no\n' ;;
    's "allow-downgrade"') printf 'allow-downgrade\n' ;;
    's "opportunistic"') printf 'opportunistic\n' ;;
    *) return 1 ;;
  esac
}

restore_snapshot() {
  local failed=0 current_pid
  current_pid=$(systemctl show -p MainPID --value systemd-resolved) || return 1
  if [[ $current_pid != "$DAEMON_PID" || $(cat "/sys/class/net/$IFACE/ifindex") != "$INDEX" || $(cat "/sys/class/net/$IFACE/address") != "$MAC" ]]; then
    printf '[FAIL] Resolver/interface identity changed; saved state retained for manual review.\n' >&2
    return 1
  fi
  if (( SAVED_DNSSEC )); then
    if ! timeout 15s resolvectl dnssec "$IFACE" "$OLD_DNSSEC"; then failed=1; fi
  fi
  if (( SAVED_DOT )); then
    if ! timeout 15s resolvectl dnsovertls "$IFACE" "$OLD_DOT"; then failed=1; fi
  fi
  if (( SAVED_DNSSEC )); then
    if [[ $(read_policy DNSSEC) != "$OLD_DNSSEC" ]]; then failed=1; fi
  fi
  if (( SAVED_DOT )); then
    if [[ $(read_policy DNSOverTLS) != "$OLD_DOT" ]]; then failed=1; fi
  fi
  if (( failed )); then
    printf '[FAIL] Recovery incomplete. State retained at %s\n' "$STATE_FILE" >&2
    return 1
  fi
  rm -f -- "$STATE_FILE" || return 1
  note 'Saved effective link policies restored. Verify manager configuration and DNS again.'
}

cleanup() {
  local rc=$?
  trap - EXIT
  if (( PENDING )); then
    printf '[WARN] Failure/interruption: attempting to restore saved effective link policies.\n' >&2
    if ! restore_snapshot; then rc=2; fi
  fi
  if [[ -n $TMP_STATE ]]; then rm -f -- "$TMP_STATE" || true; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $MODE == restore ]]; then
  [[ -f $STATE_FILE && ! -L $STATE_FILE && $(stat -c '%u:%a' "$STATE_FILE") == 0:600 ]] || fail 'No valid private saved state for this interface.'
  mapfile -t SAVED <"$STATE_FILE"
  (( ${#SAVED[@]} == 9 )) || fail 'Unexpected saved-state format.'
  [[ ${SAVED[0]} == v1 && ${SAVED[1]} == "$INDEX" && ${SAVED[2]} == "$MAC" && ${SAVED[3]} == "$DAEMON_PID" ]] || fail 'Saved state is stale: resolver/interface changed. Inspect it manually; it was not replayed.'
  OLD_DNSSEC=${SAVED[4]}
  OLD_DOT=${SAVED[5]}
  SAVED_DNSSEC=${SAVED[6]}
  SAVED_DOT=${SAVED[7]}
  [[ $OLD_DNSSEC =~ ^(yes|no|allow-downgrade)$ && $OLD_DOT =~ ^(yes|no|opportunistic)$ && $SAVED_DNSSEC =~ ^[01]$ && $SAVED_DOT =~ ^[01]$ && ${SAVED[8]} == "$IFACE" ]] || fail 'Invalid saved policy values.'
  if restore_snapshot; then exit 0; fi
  fail 'Restore incomplete; use the retained state and service diagnostics.' 2
fi

[[ ! -e $STATE_FILE && ! -L $STATE_FILE ]] || fail 'Saved state already exists. Restore or reconcile it before another workaround.'
OLD_DNSSEC=$(read_policy DNSSEC) || fail 'Cannot capture effective DNSSEC policy; no workaround applied.'
OLD_DOT=$(read_policy DNSOverTLS) || fail 'Cannot capture effective DNS-over-TLS policy; no workaround applied.'
[[ $OLD_DNSSEC =~ ^(yes|no|allow-downgrade)$ && $OLD_DOT =~ ^(yes|no|opportunistic)$ ]] || fail 'Unexpected policy values.'
SAVED_DNSSEC=$DISABLE_DNSSEC
SAVED_DOT=$DISABLE_DOT
TMP_STATE=$(mktemp "$STATE_DIR/.state.XXXXXXXX")
printf '%s\n' v1 "$INDEX" "$MAC" "$DAEMON_PID" "$OLD_DNSSEC" "$OLD_DOT" "$SAVED_DNSSEC" "$SAVED_DOT" "$IFACE" >"$TMP_STATE"
mv -T -- "$TMP_STATE" "$STATE_FILE"
TMP_STATE=''
PENDING=1
if (( DISABLE_DNSSEC )); then
  note 'Explicit workaround: disabling DNSSEC validation for every query using this link.'
  timeout 15s resolvectl dnssec "$IFACE" no
fi
if (( DISABLE_DOT )); then
  note 'Explicit workaround: disabling DNS-over-TLS encryption for this link.'
  timeout 15s resolvectl dnsovertls "$IFACE" no
fi
timeout 15s resolvectl flush-caches
timeout 15s resolvectl reset-server-features
if (( DISABLE_DNSSEC )); then
  [[ $(read_policy DNSSEC) == no ]] || fail 'DNSSEC policy did not remain effective; recovery will be attempted.' 2
fi
if (( DISABLE_DOT )); then
  [[ $(read_policy DNSOverTLS) == no ]] || fail 'DNS-over-TLS policy did not remain effective; recovery will be attempted.' 2
fi
if ! check_dns; then fail 'Workaround did not restore DNS + NSS resolution; recovery will be attempted.' 2; fi
PENDING=0
note 'DNS + NSS resolution succeeded with the temporary policy. Root cause remains unproven.'
printf 'Restore promptly: sudo bash fix-zerotier-dns.sh --restore --interface %s\n' "$IFACE"
note 'No persistent configuration files or DNS server addresses were changed. HTTPS was not tested.'
