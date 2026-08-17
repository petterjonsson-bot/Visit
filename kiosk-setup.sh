#!/usr/bin/env bash
# kiosk-setup.sh - installs a resilient PIXILAB Blocks Chromium kiosk on Raspberry Pi OS
# shellcheck shell=bash
# Must remain one physical line: the trailing CR is ignored as part of the comment when a CRLF copy is run with bash.
grep -q $'\r' "$0" 2>/dev/null && normalized_script="$(mktemp)" && tr -d '\r' < "$0" > "$normalized_script" && chmod 700 "$normalized_script" && exec bash "$normalized_script" "$@" # CRLF-safe bootstrap

set -Eeuo pipefail
umask 022

SCRIPT_NAME="${0##*/}"
CONFIG_FILE="/etc/blocks-kiosk.conf"
KIOSK_BIN="/usr/local/bin/blocks-kiosk"
WATCHDOG_BIN="/usr/local/bin/blocks-kiosk-watchdog"
HEALTH_BIN="/usr/local/bin/blocks-kiosk-health"
REFRESH_BIN="/usr/local/bin/blocks-kiosk-refresh"
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_WATCHDOG_DROPIN="/etc/systemd/system.conf.d/blocks-kiosk-watchdog.conf"
NETWORKMANAGER_DROPIN="/etc/NetworkManager/conf.d/blocks-kiosk-wifi-powersave.conf"
BOOT_WATCHDOG_BEGIN="# BEGIN blocks-kiosk watchdog"
BOOT_WATCHDOG_END="# END blocks-kiosk watchdog"

KIOSK_URL="http://int1.visitlinkoping.se/spot"
PI_USER=""
MODE="stable"
ID_MODE="profile"
ID_PARAM="kiosk"
PRIMARY_IFACE="auto"
DISPLAY_BACKEND="wayland"
ENABLE_REFRESH_TIMER=true
REFRESH_TIME="04:30"
REFRESH_ACTION="restart"
NO_START=false
SERVER_WAIT_TIMEOUT=120
ENABLE_HARDWARE_WATCHDOG=true
UNINSTALL=false
PURGE_PROFILE=false
REBOOT_REQUIRED=false

usage() {
  cat <<'USAGE'
Installerar en självläkande Chromium-kiosk för PIXILAB Blocks.

Användning:
  sudo bash kiosk-setup.sh [flaggor]
  sudo bash kiosk-setup.sh --uninstall [--purge-profile]

Vanliga flaggor:
  --url URL                    Blocks spot-URL
  --user USER                  Linux-användaren som autologgas in
  --mode stable|fast|video|ultra
  --display-backend wayland|x11
  --id-mode profile|mac|none
  --id-param kiosk|spot-id     Query-parameter vid --id-mode mac
  --primary-iface IFACE        Nätverkskort för MAC-ID, eller auto
  --refresh HH:MM              Tid för daglig återställning
  --refresh-action restart|reload
  --no-refresh                 Stäng av daglig återställning
  --server-timeout SEKUNDER    Vänta så länge på servern vid start (0-600)
  --no-hardware-watchdog       Inaktivera installerarens hårdvaruwatchdog
  --no-start                   Installera och aktivera utan att starta nu
  --uninstall                  Ta bort tjänster och installerade hjälpskript
  --purge-profile              Ta även bort Chromium-profilen (med --uninstall)
  -h, --help                   Visa denna hjälp

Identitet:
  profile  Bevarar Blocks-identiteten i Chromium-profilen (rekommenderas).
  mac      Lägger till ?kiosk=<mac> eller ?spot-id=<mac> i URL:en.
  none     Ingen extra identitetshantering.
USAGE
}

log() {
  printf '[blocks-kiosk-setup] %s\n' "$*"
}

warn() {
  printf '[blocks-kiosk-setup] VARNING: %s\n' "$*" >&2
}

die() {
  printf '[blocks-kiosk-setup] FEL: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local rc=$?
  printf '[blocks-kiosk-setup] FEL på rad %s (exit %s).\n' "${BASH_LINENO[0]:-okänd}" "$rc" >&2
  exit "$rc"
}
trap on_error ERR

detect_default_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return
  fi

  getent passwd | awk -F: '
    $3 >= 1000 && $3 < 65534 && $1 != "nobody" &&
    $6 ~ /^\// && $7 !~ /(nologin|false)$/ { print $1; exit }
  '
}

PI_USER="$(detect_default_user || true)"

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$option kräver ett värde."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      require_value "$1" "${2:-}"
      KIOSK_URL="$2"
      shift 2
      ;;
    --user)
      require_value "$1" "${2:-}"
      PI_USER="$2"
      shift 2
      ;;
    --mode)
      require_value "$1" "${2:-}"
      MODE="$2"
      shift 2
      ;;
    --display-backend)
      require_value "$1" "${2:-}"
      DISPLAY_BACKEND="$2"
      shift 2
      ;;
    --id-mode)
      require_value "$1" "${2:-}"
      ID_MODE="$2"
      shift 2
      ;;
    --id-param)
      require_value "$1" "${2:-}"
      ID_PARAM="$2"
      shift 2
      ;;
    --primary-iface)
      require_value "$1" "${2:-}"
      PRIMARY_IFACE="$2"
      shift 2
      ;;
    --refresh)
      require_value "$1" "${2:-}"
      REFRESH_TIME="$2"
      ENABLE_REFRESH_TIMER=true
      shift 2
      ;;
    --refresh-action)
      require_value "$1" "${2:-}"
      REFRESH_ACTION="$2"
      shift 2
      ;;
    --no-refresh)
      ENABLE_REFRESH_TIMER=false
      shift
      ;;
    --no-start)
      NO_START=true
      shift
      ;;
    --server-timeout)
      require_value "$1" "${2:-}"
      SERVER_WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --no-hardware-watchdog)
      ENABLE_HARDWARE_WATCHDOG=false
      shift
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --purge-profile)
      PURGE_PROFILE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Okänd flagga: $1. Kör --help för hjälp."
      ;;
  esac
done

if (( EUID != 0 )); then
  command -v sudo >/dev/null 2>&1 || die "Skriptet måste köras som root och sudo saknas."
  exec sudo -E bash "$0" \
    --url "$KIOSK_URL" \
    --user "$PI_USER" \
    --mode "$MODE" \
    --display-backend "$DISPLAY_BACKEND" \
    --id-mode "$ID_MODE" \
    --id-param "$ID_PARAM" \
    --primary-iface "$PRIMARY_IFACE" \
    --refresh "$REFRESH_TIME" \
    --refresh-action "$REFRESH_ACTION" \
    $(if ! $ENABLE_REFRESH_TIMER; then printf '%s' '--no-refresh'; fi) \
    $(if $NO_START; then printf '%s' '--no-start'; fi) \
    --server-timeout "$SERVER_WAIT_TIMEOUT" \
    $(if ! $ENABLE_HARDWARE_WATCHDOG; then printf '%s' '--no-hardware-watchdog'; fi) \
    $(if $UNINSTALL; then printf '%s' '--uninstall'; fi) \
    $(if $PURGE_PROFILE; then printf '%s' '--purge-profile'; fi)
fi

remove_boot_watchdog_block() {
  local boot_config=""
  for candidate in /boot/firmware/config.txt /boot/config.txt; do
    if [[ -f "$candidate" ]] && grep -qF "$BOOT_WATCHDOG_BEGIN" "$candidate"; then
      boot_config="$candidate"
      break
    fi
  done

  if [[ -n "$boot_config" ]]; then
    sed -i "\|^${BOOT_WATCHDOG_BEGIN}$|,\|^${BOOT_WATCHDOG_END}$|d" "$boot_config"
    REBOOT_REQUIRED=true
  fi
}

uninstall_kiosk() {
  local installed_profile=""
  local installed_home=""

  if [[ -r "$CONFIG_FILE" ]]; then
    # Filen skapas av installeraren, ägs av root och innehåller endast shell-assignments.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    installed_profile="${PROFILE_DIR:-}"
    installed_home="${USER_HOME:-}"
  fi

  systemctl disable --now \
    kiosk-refresh.timer chrome-watchdog.service kiosk.service \
    >/dev/null 2>&1 || true
  systemctl stop kiosk-refresh.service >/dev/null 2>&1 || true

  rm -f \
    "$SYSTEMD_DIR/kiosk.service" \
    "$SYSTEMD_DIR/chrome-watchdog.service" \
    "$SYSTEMD_DIR/kiosk-refresh.service" \
    "$SYSTEMD_DIR/kiosk-refresh.timer" \
    "$KIOSK_BIN" "$WATCHDOG_BIN" "$HEALTH_BIN" "$REFRESH_BIN" \
    "$CONFIG_FILE" \
    /etc/logrotate.d/blocks-kiosk \
    "$SYSTEMD_WATCHDOG_DROPIN" \
    "$NETWORKMANAGER_DROPIN"

  remove_boot_watchdog_block
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if $PURGE_PROFILE; then
    [[ -n "$installed_profile" && -n "$installed_home" ]] \
      || die "Kan inte fastställa den installerade profilens sökväg."
    [[ "$installed_profile" == "$installed_home/.config/chromium-blocks" ]] \
      || die "Vägrar ta bort oväntad profilsökväg: $installed_profile"
    rm -rf -- "$installed_profile"
    log "Chromium-profilen togs bort permanent: $installed_profile"
  elif [[ -n "$installed_profile" ]]; then
    log "Chromium-profilen behölls: $installed_profile"
  fi

  log "Kiosktjänsterna är avinstallerade."
  $REBOOT_REQUIRED && log "Starta om Raspberry Pi för att släppa hårdvaruwatchdogen."
}

if $UNINSTALL; then
  uninstall_kiosk
  exit 0
fi

$PURGE_PROFILE && die "--purge-profile får endast användas tillsammans med --uninstall."

[[ -n "$PI_USER" ]] || die "Kunde inte hitta en vanlig användare. Ange --user USER."
[[ "$PI_USER" != "root" ]] || die "Kiosken får inte köras som root. Ange en vanlig desktop-användare."
id -u "$PI_USER" >/dev/null 2>&1 || die "Användaren finns inte: $PI_USER"

case "$MODE" in
  stable|fast|video|ultra) ;;
  *) die "Ogiltigt --mode: $MODE (stable, fast, video eller ultra)." ;;
esac

case "$DISPLAY_BACKEND" in
  wayland|x11) ;;
  *) die "Ogiltigt --display-backend: $DISPLAY_BACKEND (wayland eller x11)." ;;
esac

case "$ID_MODE" in
  profile|mac|none) ;;
  *) die "Ogiltigt --id-mode: $ID_MODE (profile, mac eller none)." ;;
esac

case "$REFRESH_ACTION" in
  restart|reload) ;;
  *) die "Ogiltigt --refresh-action: $REFRESH_ACTION (restart eller reload)." ;;
esac

[[ "$KIOSK_URL" =~ ^https?://[^[:space:]\"\\]+$ ]] \
  || die "--url måste vara en http/https-URL utan blanksteg, citattecken eller backslash."

[[ "$ID_PARAM" =~ ^[A-Za-z0-9._~-]+$ ]] \
  || die "--id-param innehåller otillåtna tecken."

[[ "$PRIMARY_IFACE" == "auto" || "$PRIMARY_IFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] \
  || die "--primary-iface innehåller otillåtna tecken."

if [[ "$REFRESH_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  :
else
  die "Ogiltig tid för --refresh: $REFRESH_TIME (förväntat HH:MM)."
fi

[[ "$SERVER_WAIT_TIMEOUT" =~ ^[0-9]+$ ]] \
  || die "--server-timeout måste vara ett heltal."
(( SERVER_WAIT_TIMEOUT >= 0 && SERVER_WAIT_TIMEOUT <= 600 )) \
  || die "--server-timeout måste vara mellan 0 och 600 sekunder."

command -v systemctl >/dev/null 2>&1 || die "systemd krävs."
[[ "$(ps -p 1 -o comm=)" == "systemd" ]] || die "systemd måste vara init-system."
command -v apt-get >/dev/null 2>&1 || die "apt-get krävs."

USER_HOME="$(getent passwd "$PI_USER" | cut -d: -f6)"
KIOSK_UID="$(id -u "$PI_USER")"
KIOSK_GROUP="$(id -gn "$PI_USER")"
PROFILE_DIR="$USER_HOME/.config/chromium-blocks"
XDG_RUNTIME_DIR="/run/user/$KIOSK_UID"
XAUTHORITY="$USER_HOME/.Xauthority"
WAYLAND_DISPLAY="wayland-0"
DISPLAY_NUMBER=":0"

OS_VERSION_ID=""
if [[ -r /etc/os-release ]]; then
  OS_VERSION_ID="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release)"
fi

[[ -d "$USER_HOME" ]] || die "Hemkatalogen saknas: $USER_HOME"

IS_RASPBERRY_PI=false
if [[ -r /proc/device-tree/model ]] && tr -d '\0' < /proc/device-tree/model | grep -qi 'raspberry pi'; then
  IS_RASPBERRY_PI=true
else
  warn "Maskinen identifieras inte som Raspberry Pi; Pi-specifika inställningar hoppas över."
fi

if $IS_RASPBERRY_PI && [[ ! -e /etc/init.d/lightdm ]]; then
  die "LightDM/desktop saknas. Installera Raspberry Pi OS with Desktop (64-bit), inte Lite."
fi

log "Installerar PIXILAB Blocks-kiosk"
printf '  Användare       : %s\n' "$PI_USER"
printf '  URL             : %s\n' "$KIOSK_URL"
printf '  Renderingsläge  : %s\n' "$MODE"
printf '  Display-backend : %s\n' "$DISPLAY_BACKEND"
printf '  Identitet       : %s\n' "$ID_MODE"
printf '  Daglig åtgärd   : %s (%s, %s)\n' \
  "$ENABLE_REFRESH_TIMER" "$REFRESH_TIME" "$REFRESH_ACTION"
printf '  Hårdvaruwatchdog: %s\n' "$ENABLE_HARDWARE_WATCHDOG"

if $IS_RASPBERRY_PI && command -v raspi-config >/dev/null 2>&1; then
  log "Konfigurerar desktop-autologin för $PI_USER."
  SUDO_USER="$PI_USER" raspi-config nonint do_boot_behaviour B4 \
    || die "Kunde inte aktivera desktop-autologin med raspi-config."

  if [[ "$DISPLAY_BACKEND" == "wayland" && "$OS_VERSION_ID" =~ ^[0-9]+$ ]] \
     && (( 10#$OS_VERSION_ID >= 13 )); then
    command -v labwc >/dev/null 2>&1 \
      || die "Raspberry Pi OS $OS_VERSION_ID använder Wayland som standard men labwc saknas. Installera Raspberry Pi OS with Desktop."
    log "Raspberry Pi OS $OS_VERSION_ID använder labwc/Wayland som standard; ingen raspi-config-växling behövs."
  elif [[ "$DISPLAY_BACKEND" == "wayland" ]]; then
    if ! SUDO_USER="$PI_USER" raspi-config nonint do_wayland W3; then
      warn "raspi-config accepterade inte W3; provar äldre Wayland-argumentet 0."
      SUDO_USER="$PI_USER" raspi-config nonint do_wayland 0 \
        || die "Kunde inte aktivera Wayland/labwc med raspi-config."
    fi
  else
    if ! SUDO_USER="$PI_USER" raspi-config nonint do_wayland W1; then
      warn "raspi-config accepterade inte W1; provar äldre X11-argumentet 1."
      SUDO_USER="$PI_USER" raspi-config nonint do_wayland 1 \
        || die "Kunde inte aktivera X11 med raspi-config."
    fi
  fi

  SUDO_USER="$PI_USER" raspi-config nonint do_blanking 1 \
    || warn "Kunde inte stänga av skärmblankning via raspi-config."
  REBOOT_REQUIRED=true
fi

log "Installerar paket."
apt-get update
COMMON_PACKAGES=(
  ca-certificates coreutils curl dbus-x11 imagemagick iproute2
  procps python3-minimal sed util-linux x11-xserver-utils
)
if [[ "$DISPLAY_BACKEND" == "wayland" ]]; then
  COMMON_PACKAGES+=(grim swayidle wtype wlr-randr)
else
  COMMON_PACKAGES+=(unclutter xdotool)
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y "${COMMON_PACKAGES[@]}"

CHROME_BIN=""
for candidate in /usr/bin/chromium /usr/bin/chromium-browser /snap/bin/chromium; do
  if [[ -x "$candidate" ]]; then
    CHROME_BIN="$candidate"
    break
  fi
done

if [[ -z "$CHROME_BIN" ]]; then
  log "Installerar Chromium."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y chromium; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser
  fi

  for candidate in /usr/bin/chromium /usr/bin/chromium-browser; do
    if [[ -x "$candidate" ]]; then
      CHROME_BIN="$candidate"
      break
    fi
  done
fi

[[ -n "$CHROME_BIN" ]] || die "Kunde inte hitta eller installera Chromium."
log "Chromium: $CHROME_BIN"

install -d -m 755 /usr/local/bin "$SYSTEMD_DIR" /etc/systemd/system.conf.d
install -d -o "$PI_USER" -g "$KIOSK_GROUP" -m 755 \
  "$PROFILE_DIR" "$PROFILE_DIR/cache" "$PROFILE_DIR/disk-cache" "$PROFILE_DIR/CrashReports"
chown -R "$PI_USER:$KIOSK_GROUP" "$PROFILE_DIR"

install_labwc_cursor_hiding() {
  [[ "$DISPLAY_BACKEND" == "wayland" ]] || return 0
  command -v labwc >/dev/null 2>&1 || {
    warn "Wayland-muspekaren kan inte döljas automatiskt eftersom labwc saknas."
    return 0
  }

  local labwc_dir="$USER_HOME/.config/labwc"
  local rc_file="$labwc_dir/rc.xml"
  local begin='<!-- BEGIN blocks-kiosk cursor -->'
  local end='<!-- END blocks-kiosk cursor -->'

  install -d -o "$PI_USER" -g "$KIOSK_GROUP" -m 755 "$labwc_dir"

  if [[ ! -e "$rc_file" ]]; then
    cat > "$rc_file" <<'LABWC_RC'
<?xml version="1.0"?>
<labwc_config>
  <keyboard>
    <!-- BEGIN blocks-kiosk cursor -->
    <keybind key="A-W-h">
      <action name="HideCursor" />
      <action name="WarpCursor" x="-1" y="-1" />
    </keybind>
    <!-- END blocks-kiosk cursor -->
  </keyboard>
</labwc_config>
LABWC_RC
  else
    sed -i "\|^[[:space:]]*${begin}$|,\|^[[:space:]]*${end}$|d" "$rc_file"

    if grep -q '</keyboard>' "$rc_file"; then
      sed -i '/<\/keyboard>/i\
    <!-- BEGIN blocks-kiosk cursor -->\
    <keybind key="A-W-h">\
      <action name="HideCursor" />\
      <action name="WarpCursor" x="-1" y="-1" />\
    </keybind>\
    <!-- END blocks-kiosk cursor -->' "$rc_file"
    elif grep -q '</openbox_config>' "$rc_file"; then
      sed -i '/<\/openbox_config>/i\
  <keyboard>\
    <!-- BEGIN blocks-kiosk cursor -->\
    <keybind key="A-W-h">\
      <action name="HideCursor" />\
      <action name="WarpCursor" x="-1" y="-1" />\
    </keybind>\
    <!-- END blocks-kiosk cursor -->\
  </keyboard>' "$rc_file"
    elif grep -q '</labwc_config>' "$rc_file"; then
      sed -i '/<\/labwc_config>/i\
  <keyboard>\
    <!-- BEGIN blocks-kiosk cursor -->\
    <keybind key="A-W-h">\
      <action name="HideCursor" />\
      <action name="WarpCursor" x="-1" y="-1" />\
    </keybind>\
    <!-- END blocks-kiosk cursor -->\
  </keyboard>' "$rc_file"
    else
      warn "Kunde inte lägga till Labwc-bindning för dold muspekare i $rc_file."
      return 0
    fi
  fi

  chown "$PI_USER:$KIOSK_GROUP" "$rc_file"
  log "Labwc döljer muspekaren efter 10 sekunders inaktivitet."
}

install_labwc_cursor_hiding

write_config() {
  local temp_config
  temp_config="$(mktemp)"
  {
    printf 'KIOSK_USER=%q\n' "$PI_USER"
    printf 'KIOSK_GROUP=%q\n' "$KIOSK_GROUP"
    printf 'KIOSK_UID=%q\n' "$KIOSK_UID"
    printf 'USER_HOME=%q\n' "$USER_HOME"
    printf 'KIOSK_URL=%q\n' "$KIOSK_URL"
    printf 'CHROME_BIN=%q\n' "$CHROME_BIN"
    printf 'PROFILE_DIR=%q\n' "$PROFILE_DIR"
    printf 'MODE=%q\n' "$MODE"
    printf 'DISPLAY_BACKEND=%q\n' "$DISPLAY_BACKEND"
    printf 'DISPLAY_NUMBER=%q\n' "$DISPLAY_NUMBER"
    printf 'XAUTHORITY=%q\n' "$XAUTHORITY"
    printf 'XDG_RUNTIME_DIR=%q\n' "$XDG_RUNTIME_DIR"
    printf 'WAYLAND_DISPLAY=%q\n' "$WAYLAND_DISPLAY"
    printf 'ID_MODE=%q\n' "$ID_MODE"
    printf 'ID_PARAM=%q\n' "$ID_PARAM"
    printf 'PRIMARY_IFACE=%q\n' "$PRIMARY_IFACE"
    printf 'SERVER_WAIT_TIMEOUT=%q\n' "$SERVER_WAIT_TIMEOUT"
    printf 'REFRESH_ACTION=%q\n' "$REFRESH_ACTION"
    printf 'REMOTE_DEBUGGING_PORT=%q\n' "9222"
    printf 'SERVER_CHECK_INTERVAL=%q\n' "20"
    printf 'SNAPSHOT_INTERVAL=%q\n' "30"
    printf 'NO_WIN_TIMEOUT=%q\n' "45"
    printf 'SUSPECT_LIMIT=%q\n' "3"
    printf 'UNCHANGED_LIMIT=%q\n' "0"
    printf 'WHITE_MEAN_THRESHOLD=%q\n' "0.97"
    printf 'WHITE_STDDEV_THRESHOLD=%q\n' "0.02"
    printf 'DARK_MEAN_THRESHOLD=%q\n' "-1"
    printf 'FLAT_STDDEV_THRESHOLD=%q\n' "-1"
    printf 'RELOAD_BEFORE_RESTART=%q\n' "yes"
  } > "$temp_config"
  install -o root -g root -m 644 "$temp_config" "$CONFIG_FILE"
  rm -f "$temp_config"
}
write_config

install -o root -g root -m 755 /dev/stdin "$KIOSK_BIN" <<'KIOSK_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
[[ -r "$CONFIG" ]] || { echo "[blocks-kiosk] Config saknas: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
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

  local preferred path iface
  for preferred in eth0 end0 enp0s0 wlan0; do
    if [[ -r "/sys/class/net/$preferred/address" ]]; then
      printf '%s\n' "$preferred"
      return
    fi
  done

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
  local fragment=""
  local base="$url"
  local separator="?"

  if [[ "$url" == *#* ]]; then
    fragment="#${url#*#}"
    base="${url%%#*}"
  fi

  case "$base" in
    *"?$key="*|*"&$key="*)
      printf '%s\n' "$url"
      return
      ;;
  esac

  [[ "$base" == *\?* ]] && separator="&"
  [[ "$base" == *\? || "$base" == *\& ]] && separator=""
  printf '%s%s%s=%s%s\n' "$base" "$separator" "$key" "$value" "$fragment"
}

effective_url() {
  case "${ID_MODE:-profile}" in
    mac)
      local mac
      if mac="$(primary_mac)"; then
        append_query_param "$KIOSK_URL" "${ID_PARAM:-kiosk}" "$mac"
      else
        log "Kunde inte läsa MAC-adress; använder URL utan ID-parameter."
        printf '%s\n' "$KIOSK_URL"
      fi
      ;;
    profile|none|*)
      printf '%s\n' "$KIOSK_URL"
      ;;
  esac
}

session_ready() {
  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    [[ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]]
  else
    DISPLAY="${DISPLAY_NUMBER:-:0}" \
      XAUTHORITY="${XAUTHORITY}" \
      timeout 5s xset q >/dev/null 2>&1
  fi
}

wait_for_session() {
  local attempts=0
  while ! session_ready; do
    attempts=$((attempts + 1))
    if (( attempts == 1 || attempts % 12 == 0 )); then
      log "Väntar på ${DISPLAY_BACKEND} desktop-session..."
    fi
    sleep 5
  done
}

server_available() {
  curl -fsSIL \
    --connect-timeout 3 --max-time 8 \
    "$1" >/dev/null 2>&1
}

wait_for_server() {
  local url="$1"
  local timeout_seconds="${SERVER_WAIT_TIMEOUT:-120}"
  local started now

  (( timeout_seconds > 0 )) || return 0
  started="$(date +%s)"

  while ! server_available "$url"; do
    now="$(date +%s)"
    if (( now - started >= timeout_seconds )); then
      log "Servern svarade inte inom ${timeout_seconds}s; Chromium startas ändå."
      return 0
    fi
    sleep 3
  done
}

maintain_display() {
  if [[ "${DISPLAY_BACKEND:-wayland}" == "x11" ]]; then
    export DISPLAY="${DISPLAY_NUMBER:-:0}"
    export XAUTHORITY="${XAUTHORITY}"
    xset s off >/dev/null 2>&1 || true
    xset -dpms >/dev/null 2>&1 || true
    xset s noblank >/dev/null 2>&1 || true

    if command -v unclutter >/dev/null 2>&1 &&
       ! pgrep -u "$KIOSK_USER" -f "unclutter.*-root" >/dev/null 2>&1; then
      unclutter -idle 1 -root -grab >/dev/null 2>&1 &
    fi
  fi
}

start_wayland_cursor_hider() {
  [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]] || return 0
  command -v swayidle >/dev/null 2>&1 && command -v wtype >/dev/null 2>&1 || {
    log "Kan inte starta automatisk dold muspekare: swayidle eller wtype saknas."
    return 0
  }

  # Labwc-bindningen A-W-h installeras av kiosk-setup.sh och använder HideCursor.
  swayidle -w timeout 10 'wtype -M alt -M logo -P h' >/dev/null 2>&1 &
}

main() {
  export HOME="$USER_HOME"
  export USER="$KIOSK_USER"
  export LOGNAME="$KIOSK_USER"
  export XDG_RUNTIME_DIR
  export XDG_SESSION_TYPE="$DISPLAY_BACKEND"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  export WAYLAND_DISPLAY
  export DISPLAY="${DISPLAY_NUMBER:-:0}"
  export XAUTHORITY

  wait_for_session
  maintain_display
  start_wayland_cursor_hider

  mkdir -p "$PROFILE_DIR" "$PROFILE_DIR/cache" "$PROFILE_DIR/disk-cache" "$PROFILE_DIR/CrashReports"
  if ! touch "$PROFILE_DIR/.__write_test" 2>/dev/null; then
    log "Profilkatalogen är inte skrivbar: $PROFILE_DIR"
    exit 1
  fi
  rm -f "$PROFILE_DIR/.__write_test"
  rm -f \
    "$PROFILE_DIR/SingletonLock" \
    "$PROFILE_DIR/SingletonCookie" \
    "$PROFILE_DIR/SingletonSocket" \
    2>/dev/null || true

  local url
  url="$(effective_url)"
  wait_for_server "$url"

  local -a chrome_args=(
    --kiosk
    --noerrdialogs
    --disable-session-crashed-bubble
    --disable-translate
    --disable-pinch
    --no-first-run
    --autoplay-policy=no-user-gesture-required
    --overscroll-history-navigation=0
    --password-store=basic
    --disable-features=Translate,InfiniteSessionRestore
    --disable-breakpad
    --disable-crash-reporter
    --use-fake-ui-for-media-stream
    "--remote-debugging-address=127.0.0.1"
    "--remote-debugging-port=${REMOTE_DEBUGGING_PORT:-9222}"
    "--user-data-dir=$PROFILE_DIR"
    --profile-directory=Default
    "--disk-cache-dir=$PROFILE_DIR/disk-cache"
    "--data-path=$PROFILE_DIR/cache"
    "--crash-dumps-dir=$PROFILE_DIR/CrashReports"
  )

  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    chrome_args+=(--ozone-platform=wayland)
  else
    chrome_args+=(--ozone-platform=x11)
  fi

  case "${MODE:-stable}" in
    stable)
      chrome_args+=(--disable-gpu --disable-accelerated-2d-canvas --disable-gpu-rasterization)
      ;;
    fast)
      ;;
    video)
      chrome_args+=(--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy)
      ;;
    ultra)
      chrome_args+=(--use-gl=swiftshader --disable-accelerated-video-decode --disable-gpu-rasterization)
      ;;
  esac

  chrome_args+=("--app=$url")
  log "Startar Chromium: $url"
  exec "$CHROME_BIN" "${chrome_args[@]}"
}

main "$@"
KIOSK_SCRIPT

install -o root -g root -m 755 /dev/stdin "$WATCHDOG_BIN" <<'WATCHDOG_SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
umask 022

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
[[ -r "$CONFIG" ]] || { echo "[blocks-kiosk-watchdog] Config saknas: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

export DISPLAY="${DISPLAY_NUMBER:-:0}"
export XAUTHORITY
export XDG_RUNTIME_DIR
export WAYLAND_DISPLAY

STATUS_DIR="/run/blocks-kiosk"
SNAPSHOT_FILE="/tmp/blocks-kiosk-watchdog.png"
RAW_SNAPSHOT_FILE="/tmp/blocks-kiosk-watchdog-raw.png"
SNAP_PATTERNS=("Aw, Snap!" "He's dead, Jim!" "Åh nej!" "Oh no!")

MISSING_SINCE=0
LAST_SERVER_CHECK=0
LAST_SNAPSHOT_CHECK=0
LAST_DISPLAY_MAINTENANCE=0
SERVER_STATE="unknown"
SUSPECT_COUNT=0
UNCHANGED_COUNT=0
RECOVERY_STAGE=0
LAST_HASH=""

log() {
  printf '[blocks-kiosk-watchdog] %s\n' "$*"
}

notify_systemd() {
  command -v systemd-notify >/dev/null 2>&1 || return 0
  systemd-notify "$@" >/dev/null 2>&1 || true
}

json_status() {
  local state="$1"
  local reason="$2"
  local temp_status="$STATUS_DIR/status.json.$$"
  printf '{"ts":%s,"state":"%s","reason":"%s","server":"%s"}\n' \
    "$(date +%s)" "$state" "$reason" "$SERVER_STATE" > "$temp_status"
  mv -f "$temp_status" "$STATUS_DIR/status.json"
}

as_kiosk_user() {
  runuser -u "$KIOSK_USER" -- env \
    HOME="$USER_HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    XDG_SESSION_TYPE="$DISPLAY_BACKEND" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="$XAUTHORITY" \
    "$@"
}

x_ready() {
  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]
  else
    timeout 5s xset q >/dev/null 2>&1
  fi
}

window_ids() {
  timeout 5s xdotool search --onlyvisible --class "chromium-browser" 2>/dev/null ||
    timeout 5s xdotool search --onlyvisible --class "chromium" 2>/dev/null ||
    true
}

cdp_page_info() {
  local payload
  payload="$(curl -fsS --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:${REMOTE_DEBUGGING_PORT:-9222}/json/list" 2>/dev/null)" || return 1

  python3 -c '
import json, sys
try:
    targets = json.load(sys.stdin)
    page = next((item for item in targets if item.get("type") == "page"), None)
    if not page:
        raise SystemExit(1)
    print(page.get("id", ""))
    print(page.get("title", "").replace("\n", " "))
    print(page.get("url", "").replace("\n", " "))
except Exception:
    raise SystemExit(1)
' <<< "$payload"
}

browser_info() {
  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    cdp_page_info
  else
    local ids id title
    ids="$(window_ids)"
    [[ -n "$ids" ]] || return 1
    id="$(head -n1 <<< "$ids")"
    title="$(timeout 5s xdotool getwindowname "$id" 2>/dev/null || true)"
    printf '%s\n%s\n%s\n' "$id" "$title" ""
  fi
}

soft_reload() {
  local reason="$1"
  log "$reason; laddar om sidan."
  json_status "reload" "$reason"

  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    as_kiosk_user timeout 10s wtype -k F5 >/dev/null 2>&1
  else
    local ids id
    ids="$(window_ids)"
    [[ -n "$ids" ]] || return 1
    id="$(head -n1 <<< "$ids")"
    timeout 10s xdotool windowactivate --sync "$id" key --clearmodifiers F5 >/dev/null 2>&1
  fi
}

restart_kiosk() {
  local reason="$1"
  log "$reason; startar om kiosk.service."
  json_status "restart" "$reason"
  notify_systemd WATCHDOG=1
  timeout 40s systemctl restart kiosk.service || true
  sleep 10
  MISSING_SINCE=0
  SUSPECT_COUNT=0
  UNCHANGED_COUNT=0
  RECOVERY_STAGE=0
  LAST_HASH=""
}

server_available() {
  curl -fsSIL \
    --connect-timeout 3 --max-time 8 \
    "$KIOSK_URL" >/dev/null 2>&1
}

check_server() {
  local previous="$SERVER_STATE"

  if server_available; then
    SERVER_STATE="online"
    if [[ "$previous" == "offline" ]]; then
      log "Blocks-servern svarar igen."
      if ! soft_reload "Serveranslutningen återställdes"; then
        restart_kiosk "Servern återkom men omladdning misslyckades"
      fi
    fi
  else
    SERVER_STATE="offline"
    if [[ "$previous" != "offline" ]]; then
      log "Blocks-servern kan inte nås; avvaktar utan omstartsloop."
    fi
    SUSPECT_COUNT=0
    UNCHANGED_COUNT=0
    RECOVERY_STAGE=0
    LAST_HASH=""
  fi
}

maintain_display() {
  if [[ "${DISPLAY_BACKEND:-wayland}" == "x11" ]]; then
    xset s off >/dev/null 2>&1 || true
    xset -dpms >/dev/null 2>&1 || true
    xset s noblank >/dev/null 2>&1 || true
  elif command -v wlr-randr >/dev/null 2>&1; then
    as_kiosk_user timeout 5s wlr-randr >/dev/null 2>&1 || true
  fi
}

have_image_tools() {
  command -v import >/dev/null 2>&1 || command -v grim >/dev/null 2>&1
}

image_convert() {
  if command -v magick >/dev/null 2>&1; then
    timeout 10s magick "$@"
  else
    timeout 10s convert "$@"
  fi
}

capture_snapshot() {
  rm -f "$SNAPSHOT_FILE" "$RAW_SNAPSHOT_FILE"

  if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
    as_kiosk_user timeout 10s grim -t png "$RAW_SNAPSHOT_FILE" >/dev/null 2>&1 || return 1
    image_convert "$RAW_SNAPSHOT_FILE" -resize '320x180!' "$SNAPSHOT_FILE" >/dev/null 2>&1
  else
    local info id
    info="$(browser_info)" || return 1
    id="$(sed -n '1p' <<< "$info")"
    timeout 10s import -silent -window "$id" -resize '320x180!' "$SNAPSHOT_FILE" \
      >/dev/null 2>&1
  fi
}

is_suspect_image() {
  local stats mean stddev
  stats="$(image_convert "$SNAPSHOT_FILE" -colorspace Gray \
    -format "%[fx:mean] %[fx:standard_deviation]" info: 2>/dev/null || true)"
  read -r mean stddev <<< "$stats"
  [[ -n "${mean:-}" && -n "${stddev:-}" ]] || return 1

  awk \
    -v m="$mean" \
    -v s="$stddev" \
    -v white="${WHITE_MEAN_THRESHOLD:-0.97}" \
    -v white_stddev="${WHITE_STDDEV_THRESHOLD:-0.02}" \
    -v dark="${DARK_MEAN_THRESHOLD:--1}" \
    -v flat="${FLAT_STDDEV_THRESHOLD:--1}" \
    'BEGIN { exit !(((m >= white) && (s <= white_stddev)) ||
                    ((dark >= 0) && (m <= dark)) ||
                    ((flat >= 0) && (s <= flat))) }'
}

check_unchanged_image() {
  local limit="${UNCHANGED_LIMIT:-0}"
  local hash

  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  (( limit > 0 )) || return 1

  hash="$(sha256sum "$SNAPSHOT_FILE" | awk '{print $1}')"
  if [[ "$hash" == "$LAST_HASH" ]]; then
    UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
  else
    UNCHANGED_COUNT=0
    LAST_HASH="$hash"
  fi

  (( UNCHANGED_COUNT >= limit ))
}

mkdir -p "$STATUS_DIR"
notify_systemd --ready --status="Blocks kiosk watchdog startad"
json_status "starting" "watchdog startar"

while true; do
  NOW="$(date +%s)"
  notify_systemd WATCHDOG=1

  if (( NOW - LAST_SERVER_CHECK >= ${SERVER_CHECK_INTERVAL:-20} )); then
    LAST_SERVER_CHECK="$NOW"
    check_server
  fi

  if ! x_ready; then
    MISSING_SINCE=0
    json_status "waiting" "väntar på desktop-session"
    sleep 5
    continue
  fi

  if (( NOW - LAST_DISPLAY_MAINTENANCE >= 60 )); then
    LAST_DISPLAY_MAINTENANCE="$NOW"
    maintain_display
  fi

  INFO="$(browser_info || true)"
  if [[ -z "$INFO" ]]; then
    if [[ "$SERVER_STATE" == "offline" ]]; then
      MISSING_SINCE=0
      json_status "degraded" "Blocks-servern kan inte nås"
      sleep 5
      continue
    fi

    if [[ "$MISSING_SINCE" -eq 0 ]]; then
      MISSING_SINCE="$NOW"
    elif (( NOW - MISSING_SINCE > ${NO_WIN_TIMEOUT:-45} )); then
      restart_kiosk "Inget aktivt Chromium-fönster"
    fi
    json_status "degraded" "Chromium-fönster saknas"
    sleep 5
    continue
  fi

  MISSING_SINCE=0
  TITLE="$(sed -n '2p' <<< "$INFO")"

  for pattern in "${SNAP_PATTERNS[@]}"; do
    if [[ "$TITLE" == *"$pattern"* ]]; then
      restart_kiosk "Chromium-felsida: $pattern"
      continue 2
    fi
  done

  if [[ "$SERVER_STATE" == "online" ]] &&
     have_image_tools &&
     (( NOW - LAST_SNAPSHOT_CHECK >= ${SNAPSHOT_INTERVAL:-30} )); then
    LAST_SNAPSHOT_CHECK="$NOW"

    if capture_snapshot; then
      if is_suspect_image; then
        SUSPECT_COUNT=$((SUSPECT_COUNT + 1))
        log "Misstänkt bild ${SUSPECT_COUNT}/${SUSPECT_LIMIT:-3}."
      else
        SUSPECT_COUNT=0
        RECOVERY_STAGE=0
      fi

      if check_unchanged_image; then
        restart_kiosk "Bilden har varit oförändrad för länge"
        continue
      fi

      if (( SUSPECT_COUNT >= ${SUSPECT_LIMIT:-3} )); then
        if [[ "${RELOAD_BEFORE_RESTART:-yes}" == "yes" && "$RECOVERY_STAGE" -eq 0 ]]; then
          if soft_reload "Misstänkt vit, svart eller helt platt bild"; then
            RECOVERY_STAGE=1
            SUSPECT_COUNT=0
          else
            restart_kiosk "Misstänkt bild och omladdning misslyckades"
          fi
        else
          restart_kiosk "Misstänkt bild kvarstår efter omladdning"
        fi
      fi
    fi
  fi

  if [[ "$SERVER_STATE" == "offline" ]]; then
    json_status "degraded" "Blocks-servern kan inte nås"
  else
    json_status "ok" "watchdog aktiv"
  fi
  sleep 10
done
WATCHDOG_SCRIPT

install -o root -g root -m 755 /dev/stdin "$REFRESH_BIN" <<'REFRESH_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
# shellcheck disable=SC1090
source "$CONFIG"

action="${1:-${REFRESH_ACTION:-restart}}"

case "$action" in
  restart)
    systemctl restart kiosk.service
    ;;
  reload)
    if [[ "${DISPLAY_BACKEND:-wayland}" == "wayland" ]]; then
      runuser -u "$KIOSK_USER" -- env \
        HOME="$USER_HOME" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        timeout 10s wtype -k F5
    else
      export DISPLAY="${DISPLAY_NUMBER:-:0}"
      export XAUTHORITY
      ids="$(xdotool search --onlyvisible --class chromium-browser 2>/dev/null ||
        xdotool search --onlyvisible --class chromium 2>/dev/null)"
      id="$(head -n1 <<< "$ids")"
      timeout 10s xdotool windowactivate --sync "$id" key --clearmodifiers F5
    fi
    ;;
  *)
    echo "Ogiltig åtgärd: $action" >&2
    exit 2
    ;;
esac
REFRESH_SCRIPT

install -o root -g root -m 755 /dev/stdin "$HEALTH_BIN" <<'HEALTH_SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

CONFIG="${BLOCKS_KIOSK_CONFIG:-/etc/blocks-kiosk.conf}"
[[ -r "$CONFIG" ]] || { echo '{"healthy":false,"error":"config missing"}'; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

active="$(systemctl show -p ActiveState --value kiosk.service 2>/dev/null || echo unknown)"
substate="$(systemctl show -p SubState --value kiosk.service 2>/dev/null || echo unknown)"
pid="$(systemctl show -p MainPID --value kiosk.service 2>/dev/null || echo 0)"
watchdog="$(systemctl show -p ActiveState --value chrome-watchdog.service 2>/dev/null || echo unknown)"
server="offline"
mac=""
temperature=""
throttled=""
watchdog_status="null"
healthy=false

if curl -fsSIL --connect-timeout 3 --max-time 8 "$KIOSK_URL" >/dev/null 2>&1; then
  server="online"
fi

iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}' || true)"
if [[ -n "$iface" && -r "/sys/class/net/$iface/address" ]]; then
  mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address")"
fi

if command -v vcgencmd >/dev/null 2>&1; then
  temperature="$(vcgencmd measure_temp 2>/dev/null | sed 's/^temp=//' || true)"
  throttled="$(vcgencmd get_throttled 2>/dev/null | sed 's/^throttled=//' || true)"
fi

if [[ -r /run/blocks-kiosk/status.json ]]; then
  candidate="$(cat /run/blocks-kiosk/status.json 2>/dev/null || true)"
  [[ "$candidate" == \{*\} ]] && watchdog_status="$candidate"
fi

if [[ "$active" == "active" && "$watchdog" == "active" && "$server" == "online" ]]; then
  healthy=true
fi

printf '{\n'
printf '  "healthy":%s,\n' "$healthy"
printf '  "kiosk":"%s",\n' "$active"
printf '  "substate":"%s",\n' "$substate"
printf '  "pid":%s,\n' "${pid:-0}"
printf '  "watchdog":"%s",\n' "$watchdog"
printf '  "server":"%s",\n' "$server"
printf '  "mac":"%s",\n' "$mac"
printf '  "url":"%s",\n' "$KIOSK_URL"
printf '  "mode":"%s",\n' "$MODE"
printf '  "displayBackend":"%s",\n' "$DISPLAY_BACKEND"
printf '  "idMode":"%s",\n' "$ID_MODE"
printf '  "temperature":"%s",\n' "$temperature"
printf '  "throttled":"%s",\n' "$throttled"
printf '  "watchdogStatus":%s\n' "$watchdog_status"
printf '}\n'

$healthy
HEALTH_SCRIPT

cat > "$SYSTEMD_DIR/kiosk.service" <<SYSTEMD_KIOSK
[Unit]
Description=PIXILAB Blocks Chromium kiosk
Wants=network-online.target
After=display-manager.service network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$PI_USER
Group=$KIOSK_GROUP
Environment=BLOCKS_KIOSK_CONFIG=$CONFIG_FILE
Environment=HOME=$USER_HOME
Environment=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR
Environment=XDG_SESSION_TYPE=$DISPLAY_BACKEND
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
Environment=WAYLAND_DISPLAY=$WAYLAND_DISPLAY
Environment=DISPLAY=$DISPLAY_NUMBER
Environment=XAUTHORITY=$XAUTHORITY
ExecStart=$KIOSK_BIN
Restart=always
RestartSec=5s
TimeoutStopSec=20s
KillMode=control-group
OOMScoreAdjust=-250
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
StandardOutput=journal
StandardError=journal
SyslogIdentifier=blocks-kiosk

[Install]
WantedBy=graphical.target
SYSTEMD_KIOSK

cat > "$SYSTEMD_DIR/chrome-watchdog.service" <<SYSTEMD_WATCHDOG
[Unit]
Description=PIXILAB Blocks kiosk watchdog
Requires=kiosk.service
After=kiosk.service
StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=all
Environment=BLOCKS_KIOSK_CONFIG=$CONFIG_FILE
ExecStart=$WATCHDOG_BIN
Restart=always
RestartSec=5s
WatchdogSec=90s
TimeoutStopSec=15s
RuntimeDirectory=blocks-kiosk
RuntimeDirectoryMode=0755
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
StandardOutput=journal
StandardError=journal
SyslogIdentifier=blocks-kiosk-watchdog

[Install]
WantedBy=graphical.target
SYSTEMD_WATCHDOG

cat > "$SYSTEMD_DIR/kiosk-refresh.service" <<SYSTEMD_REFRESH
[Unit]
Description=Daily PIXILAB Blocks kiosk recovery
After=kiosk.service

[Service]
Type=oneshot
Environment=BLOCKS_KIOSK_CONFIG=$CONFIG_FILE
ExecStart=$REFRESH_BIN
TimeoutStartSec=60s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=blocks-kiosk-refresh
SYSTEMD_REFRESH

cat > "$SYSTEMD_DIR/kiosk-refresh.timer" <<SYSTEMD_TIMER
[Unit]
Description=Daily PIXILAB Blocks kiosk recovery timer

[Timer]
OnCalendar=*-*-* $REFRESH_TIME:00
Persistent=true
RandomizedDelaySec=5m
AccuracySec=1m
Unit=kiosk-refresh.service

[Install]
WantedBy=timers.target
SYSTEMD_TIMER

rm -f /etc/logrotate.d/blocks-kiosk

if command -v NetworkManager >/dev/null 2>&1 ||
   systemctl list-unit-files --no-legend NetworkManager.service 2>/dev/null | grep -q '^NetworkManager.service'; then
  install -d -m 755 /etc/NetworkManager/conf.d
  cat > "$NETWORKMANAGER_DROPIN" <<'NETWORKMANAGER_CONFIG'
[connection]
wifi.powersave=2
NETWORKMANAGER_CONFIG
  systemctl reload NetworkManager.service >/dev/null 2>&1 || true
fi

configure_hardware_watchdog() {
  local boot_config=""
  local current_setting=""

  $IS_RASPBERRY_PI || return 0
  if ! $ENABLE_HARDWARE_WATCHDOG; then
    rm -f "$SYSTEMD_WATCHDOG_DROPIN"
    remove_boot_watchdog_block
    return 0
  fi


  for candidate in /boot/firmware/config.txt /boot/config.txt; do
    if [[ -f "$candidate" ]]; then
      boot_config="$candidate"
      break
    fi
  done

  if [[ -n "$boot_config" ]]; then
    current_setting="$(sed -n 's/^[[:space:]]*kernel_watchdog_timeout[[:space:]]*=[[:space:]]*//p' \
      "$boot_config" | tail -n1)"
    if [[ -z "$current_setting" ]]; then
      {
        printf '\n%s\n' "$BOOT_WATCHDOG_BEGIN"
        printf '[all]\n'
        printf 'kernel_watchdog_timeout=15\n'
        printf '%s\n' "$BOOT_WATCHDOG_END"
      } >> "$boot_config"
      REBOOT_REQUIRED=true
    elif [[ "$current_setting" == "0" ]]; then
      warn "kernel_watchdog_timeout=0 är redan satt; lämnar hårdvaruwatchdogen avstängd."
      return 0
    else
      log "Befintlig kernel_watchdog_timeout=$current_setting behålls."
    fi
  else
    warn "Hittade ingen config.txt; hårdvaruwatchdog aktiveras inte."
    return 0
  fi

  cat > "$SYSTEMD_WATCHDOG_DROPIN" <<'SYSTEMD_MANAGER_WATCHDOG'
[Manager]
RuntimeWatchdogSec=15s
SYSTEMD_MANAGER_WATCHDOG
}

configure_hardware_watchdog

systemctl daemon-reload
systemd-analyze verify \
  "$SYSTEMD_DIR/kiosk.service" \
  "$SYSTEMD_DIR/chrome-watchdog.service" \
  "$SYSTEMD_DIR/kiosk-refresh.service" \
  "$SYSTEMD_DIR/kiosk-refresh.timer"

systemctl enable kiosk.service chrome-watchdog.service
if $ENABLE_REFRESH_TIMER; then
  systemctl enable kiosk-refresh.timer
else
  systemctl disable --now kiosk-refresh.timer >/dev/null 2>&1 || true
fi

if ! $NO_START; then
  systemctl restart kiosk.service
  systemctl restart chrome-watchdog.service
  if $ENABLE_REFRESH_TIMER; then
    systemctl restart kiosk-refresh.timer
  fi

  sleep 3
  systemctl is-active --quiet kiosk.service \
    || die "kiosk.service startade inte. Kör: journalctl -u kiosk.service -n 100"
  systemctl is-active --quiet chrome-watchdog.service \
    || die "chrome-watchdog.service startade inte. Kör: journalctl -u chrome-watchdog.service -n 100"
fi

log "Installationen är klar."
printf '  Konfiguration : %s\n' "$CONFIG_FILE"
printf '  Hälsokontroll : sudo %s\n' "$HEALTH_BIN"
printf '  Status         : systemctl status kiosk.service chrome-watchdog.service\n'
printf '  Loggar         : journalctl -u kiosk.service -u chrome-watchdog.service -f\n'
if $REBOOT_REQUIRED; then
  printf '\nOBS: Starta om Raspberry Pi för att aktivera displayläge, autologin och hårdvaruwatchdog:\n'
  printf '  sudo reboot\n'
fi

