#!/usr/bin/env bash
# kiosk-setup.sh - Chromium kiosk setup for Raspberry Pi / Linux
# Usage:
#   sudo ./kiosk-setup.sh [--url URL] [--user USER] [--mode stable|fast|video|ultra]
#                         [--id-mode profile|mac|none] [--id-param kiosk|spot-id]
#                         [--refresh HH:MM] [--no-refresh] [--no-start]
#
# Notes:
#   profile = preserves browser/profile based Blocks identity
#   mac     = appends ?kiosk=<mac> or ?spot-id=<mac> to the URL
#   none    = no identity handling

set -Eeuo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

if [ -r "$0" ] && grep -q $'\r' "$0" 2>/dev/null; then
  echo "[setup-kiosk] CRLF detected, restarting with normalized copy..."
  tmp="$(mktemp)"
  tr -d '\r' < "$0" > "$tmp"
  chmod +x "$tmp"
  exec bash "$tmp" "$@"
fi

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

KIOSK_URL="https://int1.visitlinkoping.se/spot"
PI_USER="${SUDO_USER:-${USER:-pi}}"
MODE="stable"
ID_MODE="profile"
ID_PARAM="kiosk"
PRIMARY_IFACE="auto"
ENABLE_REFRESH_TIMER=true
REFRESH_TIME="04:30"
NO_START=false
SERVER_WAIT_TIMEOUT=120

CONFIG_FILE="/etc/blocks-kiosk.conf"
KIOSK_BIN="/usr/local/bin/blocks-kiosk"
WATCHDOG_BIN="/usr/local/bin/blocks-kiosk-watchdog"
HEALTH_BIN="/usr/local/bin/blocks-kiosk-health"

usage() {
  sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) KIOSK_URL="$2"; shift 2 ;;
    --user) PI_USER="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --id-mode) ID_MODE="$2"; shift 2 ;;
    --id-param) ID_PARAM="$2"; shift 2 ;;
    --primary-iface) PRIMARY_IFACE="$2"; shift 2 ;;
    --refresh) REFRESH_TIME="$2"; ENABLE_REFRESH_TIMER=true; shift 2 ;;
    --no-refresh) ENABLE_REFRESH_TIMER=false; shift ;;
    --no-start) NO_START=true; shift ;;
    --server-timeout) SERVER_WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

case "$MODE" in
  stable|fast|video|ultra) ;;
  *) echo "Invalid --mode: $MODE"; exit 1 ;;
esac

case "$ID_MODE" in
  profile|mac|none) ;;
  *) echo "Invalid --id-mode: $ID_MODE"; exit 1 ;;
esac

if ! [[ "$REFRESH_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
  echo "Invalid --refresh time: $REFRESH_TIME"
  exit 1
fi

if ! id -u "$PI_USER" >/dev/null 2>&1; then
  echo "User does not exist: $PI_USER"
  exit 1
fi

USER_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
PROFILE_DIR="${USER_HOME}/.config/chromium-blocks"

echo "==> Installing Chromium kiosk"
echo "    User       : $PI_USER"
echo "    URL        : $KIOSK_URL"
echo "    Mode       : $MODE"
echo "    ID mode    : $ID_MODE"
echo "    ID param   : $ID_PARAM"
echo "    Refresh    : $ENABLE_REFRESH_TIMER ($REFRESH_TIME)"
echo "    No start   : $NO_START"

if command -v raspi-config >/dev/null 2>&1; then
  if raspi-config nonint help 2>/dev/null | grep -q 'do_boot_behaviour'; then
    raspi-config nonint do_boot_behaviour B4 || true
  fi
  if raspi-config nonint help 2>/dev/null | grep -q 'do_wayland'; then
    raspi-config nonint do_wayland 1 || true
  fi
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl dbus-x11 imagemagick iproute2 procps sed \
  unclutter x11-xserver-utils xdotool

CHROME_BIN=""
for c in /usr/bin/chromium-browser /usr/bin/chromium /snap/bin/chromium; do
  [[ -x "$c" ]] && CHROME_BIN="$c" && break
done

if [[ -z "$CHROME_BIN" ]]; then
  echo "==> Installing Chromium..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y chromium
  for c in /usr/bin/chromium-browser /usr/bin/chromium; do
    [[ -x "$c" ]] && CHROME_BIN="$c" && break
  done
fi

if [[ -z "$CHROME_BIN" ]]; then
  echo "Could not find or install Chromium."
  exit 1
fi

install -d -m 755 /usr/local/bin /etc/systemd/system /var/log/blocks-kiosk
install -d -o "$PI_USER" -g "$PI_USER" -m 755 \
  "$PROFILE_DIR" "$PROFILE_DIR/cache" "$PROFILE_DIR/disk-cache" "$PROFILE_DIR/CrashReports"

{
  printf 'KIOSK_USER=%q\n' "$PI_USER"
  printf 'USER_HOME=%q\n' "$USER_HOME"
  printf 'KIOSK_URL=%q\n' "$KIOSK_URL"
  printf 'CHROME_BIN=%q\n' "$CHROME_BIN"
  printf 'PROFILE_DIR=%q\n' "$PROFILE_DIR"
  printf 'MODE=%q\n' "$MODE"
  printf 'ID_MODE=%q\n' "$ID_MODE"
  printf 'ID_PARAM=%q\n' "$ID_PARAM"
  printf 'PRIMARY_IFACE=%q\n' "$PRIMARY_IFACE"
  printf 'SERVER_WAIT_TIMEOUT=%q\n' "$SERVER_WAIT_TIMEOUT"
  printf 'SNAPSHOT_INTERVAL=%q\n' "30"
  printf 'NO_WIN_TIMEOUT=%q\n' "30"
  printf 'SUSPECT_LIMIT=%q\n' "3"
  printf 'UNCHANGED_LIMIT=%q\n' "0"
  printf 'WHITE_MEAN_THRESHOLD=%q\n' "0.97"
  printf 'DARK_MEAN_THRESHOLD=%q\n' "0.02"
  printf 'FLAT_STDDEV_THRESHOLD=%q\n' "0.003"
  printf 'RELOAD_BEFORE_RESTART=%q\n' "yes"
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

cat > "$KIOSK_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
source "$CONFIG"

log() {
  printf '[blocks-kiosk] %s\n' "$*"
}

choose_iface() {
  if [[ "${PRIMARY_IFACE:-auto}" != "auto" ]]; then
    printf '%s\n' "$PRIMARY_IFACE"
    return
  fi

  local route_iface=""
  route_iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)"
  if [[ -n "$route_iface" && -r "/sys/class/net/$route_iface/address" ]]; then
    printf '%s\n' "$route_iface"
    return
  fi

  local preferred
  for preferred in eth0 enp0s0 end0 wlan0; do
    if [[ -r "/sys/class/net/$preferred/address" ]]; then
      printf '%s\n' "$preferred"
      return
    fi
  done

  local path iface
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "$iface" == "lo" ]] && continue
    [[ -r "$path/address" ]] || continue
    printf '%s\n' "$iface"
    return
  done
}

primary_mac() {
  local iface mac
  iface="$(choose_iface || true)"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/address" ]]; then
    mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address")"
    if [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
      printf '%s\n' "$mac"
      return 0
    fi
  fi
  return 1
}

append_query_param() {
  local url="$1"
  local key="$2"
  local value="$3"
  local sep="?"

  case "$url" in
    *"?$key="*|*"&$key="*) printf '%s\n' "$url"; return ;;
  esac

  [[ "$url" == *\?* ]] && sep="&"
  [[ "$url" == *\? || "$url" == *\& ]] && sep=""

  printf '%s%s%s=%s\n' "$url" "$sep" "$key" "$value"
}

effective_url() {
  case "${ID_MODE:-profile}" in
    mac)
      local mac
      if mac="$(primary_mac)"; then
        append_query_param "$KIOSK_URL" "${ID_PARAM:-kiosk}" "$mac"
      else
        log "Could not determine MAC address, using URL without ID parameter"
        printf '%s\n' "$KIOSK_URL"
      fi
      ;;
    none|profile|*)
      printf '%s\n' "$KIOSK_URL"
      ;;
  esac
}

wait_for_x() {
  export DISPLAY=":0"
  export XAUTHORITY="${USER_HOME}/.Xauthority"
  export XDG_RUNTIME_DIR="/run/user/$(id -u "$KIOSK_USER")"

  mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

  for _ in $(seq 1 90); do
    if xset q >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  log "X did not become ready, continuing anyway"
}

wait_for_server() {
  local url="$1"
  local timeout="${SERVER_WAIT_TIMEOUT:-120}"
  local start now

  command -v curl >/dev/null 2>&1 || return 0
  start="$(date +%s)"

  while true; do
    if curl -kfsS --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout )); then
      log "Server did not answer within ${timeout}s, starting Chromium anyway"
      return 0
    fi

    sleep 2
  done
}

chrome_flags_for_mode() {
  case "${MODE:-stable}" in
    stable)
      printf '%s\n' "--disable-gpu --disable-accelerated-2d-canvas --disable-gpu-rasterization"
      ;;
    fast)
      printf '%s\n' ""
      ;;
    video)
      printf '%s\n' "--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy"
      ;;
    ultra)
      printf '%s\n' "--use-gl=swiftshader --disable-accelerated-video-decode --disable-gpu-rasterization"
      ;;
  esac
}

main() {
  wait_for_x

  xset s off || true
  xset -dpms || true
  xset s noblank || true

  if ! pgrep -u "$KIOSK_USER" -f "unclutter.*-root" >/dev/null 2>&1; then
    unclutter -idle 1 -root -grab >/dev/null 2>&1 &
  fi

  mkdir -p "$PROFILE_DIR" "$PROFILE_DIR/cache" "$PROFILE_DIR/disk-cache" "$PROFILE_DIR/CrashReports"
  if ! touch "$PROFILE_DIR/.__write_test" 2>/dev/null; then
    log "Profile dir is not writable: $PROFILE_DIR"
    exit 1
  fi
  rm -f "$PROFILE_DIR/.__write_test" 2>/dev/null || true
  rm -f "$PROFILE_DIR/SingletonLock" "$PROFILE_DIR/SingletonCookie" 2>/dev/null || true

  local url gpu_flags
  url="$(effective_url)"
  gpu_flags="$(chrome_flags_for_mode)"
  wait_for_server "$url"

  log "Starting Chromium: $url"

  # shellcheck disable=SC2086
  exec "$CHROME_BIN" \
    --kiosk \
    --noerrdialogs \
    --disable-session-crashed-bubble \
    --disable-translate \
    --no-first-run \
    --fast \
    --fast-start \
    --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
    --autoplay-policy=no-user-gesture-required \
    --overscroll-history-navigation=0 \
    --password-store=basic \
    --disable-features=Translate,InfiniteSessionRestore \
    --enable-features=OverlayScrollbar \
    --use-fake-ui-for-media-stream \
    --user-data-dir="$PROFILE_DIR" \
    --profile-directory=Default \
    --disk-cache-dir="$PROFILE_DIR/disk-cache" \
    --data-path="$PROFILE_DIR/cache" \
    --crash-dumps-dir="$PROFILE_DIR/CrashReports" \
    $gpu_flags \
    --app="$url"
}

main "$@"
EOF
chmod 755 "$KIOSK_BIN"

cat > "$WATCHDOG_BIN" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
source "$CONFIG"

export DISPLAY=":0"
export XAUTHORITY="${USER_HOME}/.Xauthority"

STATUS_DIR="/run/blocks-kiosk"
SNAPSHOT_FILE="/tmp/blocks-kiosk-watchdog.png"
SNAP_PATTERNS=("Aw, Snap!" "He's dead, Jim!" "Åh nej!" "Oh no!")

MISSING_SINCE=0
LAST_SNAPSHOT_CHECK=0
SUSPECT_COUNT=0
UNCHANGED_COUNT=0
LAST_HASH=""

mkdir -p "$STATUS_DIR"

log() {
  printf '[blocks-kiosk-watchdog] %s\n' "$*"
}

json_status() {
  local state reason
  state="$1"
  reason="$2"
  printf '{"ts":%s,"state":"%s","reason":"%s"}\n' \
    "$(date +%s)" "$state" "$reason" > "$STATUS_DIR/status.json"
}

restart_kiosk() {
  local reason="$1"
  log "$reason, restarting kiosk.service"
  json_status "restart" "$reason"
  systemctl restart kiosk.service || true
  sleep 10
  MISSING_SINCE=0
  SUSPECT_COUNT=0
  UNCHANGED_COUNT=0
  LAST_HASH=""
}

soft_reload() {
  local reason="$1"
  log "$reason, sending F5"
  json_status "reload" "$reason"
  xdotool search --onlyvisible --class "chromium-browser" windowactivate --sync key F5 >/dev/null 2>&1 || \
  xdotool search --onlyvisible --class "chromium" windowactivate --sync key F5 >/dev/null 2>&1 || true
}

have_image_tools() {
  command -v import >/dev/null 2>&1 && command -v convert >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1
}

window_ids() {
  xdotool search --onlyvisible --class "chromium-browser" 2>/dev/null || \
  xdotool search --onlyvisible --class "chromium" 2>/dev/null || true
}

is_suspect_image() {
  local mean stddev
  read -r mean stddev < <(convert "$SNAPSHOT_FILE" -colorspace Gray \
    -format "%[fx:mean] %[fx:standard_deviation]" info: 2>/dev/null || echo "")

  [[ -z "${mean:-}" || -z "${stddev:-}" ]] && return 1

  awk \
    -v m="$mean" \
    -v s="$stddev" \
    -v white="${WHITE_MEAN_THRESHOLD:-0.97}" \
    -v dark="${DARK_MEAN_THRESHOLD:-0.02}" \
    -v flat="${FLAT_STDDEV_THRESHOLD:-0.003}" \
    'BEGIN { exit !((m >= white) || (m <= dark) || (s <= flat)) }'
}

check_unchanged_image() {
  local limit hash
  limit="${UNCHANGED_LIMIT:-0}"
  [[ "$limit" == "0" ]] && return 1

  hash="$(sha256sum "$SNAPSHOT_FILE" | awk '{print $1}')"
  if [[ "$hash" == "$LAST_HASH" ]]; then
    UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
  else
    UNCHANGED_COUNT=0
    LAST_HASH="$hash"
  fi

  (( UNCHANGED_COUNT >= limit ))
}

while true; do
  if ! command -v xdotool >/dev/null 2>&1; then
    log "xdotool missing, sleeping"
    sleep 60
    continue
  fi

  WIN_IDS="$(window_ids)"
  if [[ -z "$WIN_IDS" ]]; then
    if [[ "$MISSING_SINCE" -eq 0 ]]; then
      MISSING_SINCE="$(date +%s)"
    else
      NOW="$(date +%s)"
      if (( NOW - MISSING_SINCE > ${NO_WIN_TIMEOUT:-30} )); then
        restart_kiosk "No visible Chromium window"
      fi
    fi
    sleep 5
    continue
  fi

  MISSING_SINCE=0
  WIN_ID="$(echo "$WIN_IDS" | head -n1)"
  TITLE="$(xdotool getwindowname "$WIN_ID" 2>/dev/null || echo "")"

  for pattern in "${SNAP_PATTERNS[@]}"; do
    if [[ "$TITLE" == *"$pattern"* ]]; then
      restart_kiosk "Chromium error page: $pattern"
      continue 2
    fi
  done

  if have_image_tools; then
    NOW="$(date +%s)"
    if (( NOW - LAST_SNAPSHOT_CHECK >= ${SNAPSHOT_INTERVAL:-30} )); then
      LAST_SNAPSHOT_CHECK="$NOW"

      if import -silent -window "$WIN_ID" -resize 320x180 "$SNAPSHOT_FILE" >/dev/null 2>&1; then
        if is_suspect_image; then
          SUSPECT_COUNT=$((SUSPECT_COUNT + 1))
          log "Suspicious image ${SUSPECT_COUNT}/${SUSPECT_LIMIT:-3}"
        else
          SUSPECT_COUNT=0
        fi

        if check_unchanged_image; then
          restart_kiosk "Image unchanged for too long"
        fi

        if (( SUSPECT_COUNT >= ${SUSPECT_LIMIT:-3} )); then
          if [[ "${RELOAD_BEFORE_RESTART:-yes}" == "yes" && "$SUSPECT_COUNT" -eq "${SUSPECT_LIMIT:-3}" ]]; then
            soft_reload "Suspicious image"
            SUSPECT_COUNT=$((SUSPECT_COUNT + 1))
          else
            restart_kiosk "Suspicious image persisted"
          fi
        fi
      fi
    fi
  fi

  json_status "ok" "watchdog alive"
  sleep 10
done
EOF
chmod 755 "$WATCHDOG_BIN"

cat > "$HEALTH_BIN" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
source "$CONFIG"

active="$(systemctl show -p ActiveState --value kiosk.service 2>/dev/null || echo unknown)"
sub="$(systemctl show -p SubState --value kiosk.service 2>/dev/null || echo unknown)"
pid="$(systemctl show -p MainPID --value kiosk.service 2>/dev/null || echo 0)"
watchdog="$(systemctl show -p ActiveState --value chrome-watchdog.service 2>/dev/null || echo unknown)"
mac=""

iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)"
if [[ -n "$iface" && -r "/sys/class/net/$iface/address" ]]; then
  mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address")"
fi

printf '{\n'
printf '  "kiosk":"%s",\n' "$active"
printf '  "substate":"%s",\n' "$sub"
printf '  "pid":%s,\n' "$pid"
printf '  "watchdog":"%s",\n' "$watchdog"
printf '  "mac":"%s",\n' "$mac"
printf '  "url":"%s",\n' "$KIOSK_URL"
printf '  "mode":"%s",\n' "$MODE"
printf '  "idMode":"%s"\n' "$ID_MODE"
printf '}\n'
EOF
chmod 755 "$HEALTH_BIN"

cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chromium Kiosk
Wants=graphical.target network-online.target
After=graphical.target network-online.target

[Service]
User=${PI_USER}
Type=simple
Environment=BLOCKS_KIOSK_CONFIG=${CONFIG_FILE}
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
ExecStart=${KIOSK_BIN}
Restart=always
RestartSec=3
KillMode=control-group
TemporaryFileSystem=/dev/shm:rw,nosuid,nodev,mode=1777,size=256M
StandardOutput=append:/var/log/blocks-kiosk/chromium.log
StandardError=append:/var/log/blocks-kiosk/chromium.log

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/chrome-watchdog.service <<EOF
[Unit]
Description=Chromium Kiosk Watchdog
After=kiosk.service
Requires=kiosk.service

[Service]
Type=simple
Environment=BLOCKS_KIOSK_CONFIG=${CONFIG_FILE}
ExecStart=${WATCHDOG_BIN}
Restart=always
RestartSec=5
StandardOutput=append:/var/log/blocks-kiosk/watchdog.log
StandardError=append:/var/log/blocks-kiosk/watchdog.log

[Install]
WantedBy=graphical.target
EOF

cat > /etc/systemd/system/kiosk-refresh.service <<EOF
[Unit]
Description=Kiosk soft reload

[Service]
User=${PI_USER}
Type=oneshot
Environment=BLOCKS_KIOSK_CONFIG=${CONFIG_FILE}
ExecStart=/bin/bash -lc 'source "\$BLOCKS_KIOSK_CONFIG"; export DISPLAY=:0 XAUTHORITY="\${USER_HOME}/.Xauthority"; xdotool search --onlyvisible --class "chromium-browser" windowactivate --sync key F5 || xdotool search --onlyvisible --class "chromium" windowactivate --sync key F5'
EOF

cat > /etc/systemd/system/kiosk-refresh.timer <<EOF
[Unit]
Description=Daily kiosk refresh

[Timer]
OnCalendar=*-*-* ${REFRESH_TIME}:00
Persistent=true
Unit=kiosk-refresh.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/blocks-kiosk <<'EOF'
/var/log/blocks-kiosk/*.log {
  weekly
  rotate 6
  compress
  missingok
  notifempty
  copytruncate
}
EOF

systemctl daemon-reload
systemctl enable kiosk.service chrome-watchdog.service

if $ENABLE_REFRESH_TIMER; then
  systemctl enable kiosk-refresh.timer
else
  systemctl disable --now kiosk-refresh.timer >/dev/null 2>&1 || true
fi

if ! $NO_START; then
  systemctl restart kiosk.service chrome-watchdog.service
  if $ENABLE_REFRESH_TIMER; then
    systemctl restart kiosk-refresh.timer
  fi
fi

echo
echo "==> Done"
echo "    Config     : ${CONFIG_FILE}"
echo "    Kiosk      : systemctl status kiosk.service"
echo "    Watchdog   : systemctl status chrome-watchdog.service"
echo "    Health     : ${HEALTH_BIN}"
echo "    Logs       : /var/log/blocks-kiosk/"
echo
echo "Examples:"
echo "    sudo ${HEALTH_BIN}"
echo "    sudo sed -i 's/^ID_MODE=.*/ID_MODE=mac/' ${CONFIG_FILE} && sudo systemctl restart kiosk.service"
