#!/usr/bin/env bash
# setup-kiosk.sh – One-shot install för Chromium-kiosk med ENHANCED WATCHDOG
# Usage:
#   sudo ./kiosk-setup.sh [--url URL] [--user <user>] [--mode stable|fast|ultra] [--no-refresh]
# Modes:
#   stable (default): GPU off (disable-gpu, raster off) – mest stabil
#   fast:             GPU on  (Chromiums standard)
#   ultra:            SwiftShader mjukvaru-GL – max stabilitet

set -euo pipefail

# Kör med bash om vi råkar startas via sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# CRLF-koll: endast om skriptet körs från en läsbar fil (inte via stdin)
if [ -r "$0" ] && grep -q $'\r' "$0" 2>/dev/null; then
  echo "[setup-kiosk] Upptäckte CRLF – fixar..."
  tmp="$(mktemp)"
  tr -d '\r' < "$0" > "$tmp"
  chmod +x "$tmp"
  exec bash "$tmp" "$@"
fi

# Auto-sudo
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# ======= Standardvärden =======
KIOSK_URL="https://int1.visitlinkoping.se/spot"
PI_USER="${SUDO_USER:-${USER:-pi}}"
MODE="stable"                # stable|fast|ultra
ENABLE_REFRESH_TIMER=true    # daglig F5 04:30

# ======= Argument =======
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)        KIOSK_URL="$2"; shift 2 ;;
    --user)       PI_USER="$2"; shift 2 ;;
    --mode)       MODE="$2"; shift 2 ;;
    --no-refresh) ENABLE_REFRESH_TIMER=false; shift ;;
    *) echo "Okänt argument: $1"; exit 1 ;;
  esac
done

echo "==> Installerar kiosk"
echo "    Användare : ${PI_USER}"
echo "    URL       : ${KIOSK_URL}"
echo "    Mode      : ${MODE}"
echo "    Daily F5  : ${ENABLE_REFRESH_TIMER}"

# ======= Kontroller =======
if ! id -u "${PI_USER}" >/dev/null 2>&1; then
  echo "Användaren ${PI_USER} finns inte."; exit 1
fi
USER_HOME=$(eval echo "~${PI_USER}")

# ======= Autologin/X11 (försök – hoppa över om ej tillgängligt) =======
if command -v raspi-config >/dev/null 2>&1; then
  if raspi-config nonint help 2>/dev/null | grep -q 'do_boot_behaviour'; then
    raspi-config nonint do_boot_behaviour B4 || true  # Autologin desktop
  fi
  if raspi-config nonint help 2>/dev/null | grep -q 'do_wayland'; then
    raspi-config nonint do_wayland 1 || true          # Försök X11
  fi
fi

# ======= Paket =======
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xdotool unclutter coreutils sed dbus-x11 imagemagick

# Chromium (hantera olika binärnamn)
CHROME_BIN=""
for c in /usr/bin/chromium-browser /usr/bin/chromium /snap/bin/chromium; do
  [[ -x "$c" ]] && CHROME_BIN="$c" && break
done
if [[ -z "$CHROME_BIN" ]]; then
  echo "==> Installerar Chromium…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y chromium
  for c in /usr/bin/chromium-browser /usr/bin/chromium; do
    [[ -x "$c" ]] && CHROME_BIN="$c" && break
  done
fi
if [[ -z "$CHROME_BIN" ]]; then
  echo "Kunde inte hitta/installera Chromium."; exit 1
fi
echo "==> Chromium: $CHROME_BIN"

# ======= Render-flaggor beroende på mode =======
GPU_FLAG=""
case "$MODE" in
  stable)
    GPU_FLAG="--disable-gpu --disable-accelerated-2d-canvas --disable-gpu-rasterization"
    ;;
  fast)
    GPU_FLAG=""  # standard: låt Chromium använda GPU
    ;;
  ultra)
    GPU_FLAG="--use-gl=swiftshader --disable-accelerated-video-decode --disable-gpu-rasterization"
    ;;
  *)
    echo "Ogiltigt --mode: $MODE (tillåtna: stable|fast|ultra)"; exit 1 ;;
esac

# Tysta kamera/mikrofon-portalen (onödig i kiosk)
MEDIA_FLAG="--use-fake-ui-for-media-stream"

# ======= Script: kiosk + watchdog =======
PROFILE_DIR="${USER_HOME}/.config/chromium"
KIOSK_SH="${USER_HOME}/kiosk.sh"
WATCHDOG_SH="${USER_HOME}/chrome_watchdog.sh"

cat > "${KIOSK_SH}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
KIOSK_URL="${KIOSK_URL}"
CHROME_BIN="${CHROME_BIN}"
DISPLAY=":0"
XAUTHORITY="${USER_HOME}/.Xauthority"
PROFILE_DIR="${PROFILE_DIR}"

export DISPLAY XAUTHORITY
export XDG_RUNTIME_DIR="/run/user/\$(id -u ${PI_USER})"

# Se till att runtime-dir finns
mkdir -p "\${XDG_RUNTIME_DIR}" || true

# Vänta tills X-session är igång
for i in {1..60}; do xset q >/dev/null 2>&1 && break; sleep 1; done

# Stäng av skärmsläckning/DPMS
xset s off || true
xset -dpms || true
xset s noblank || true

# Dölj muspekaren
unclutter -idle 1 -root -grab >/dev/null 2>&1 &

CHROME_FLAGS="--kiosk --noerrdialogs --disable-session-crashed-bubble --disable-translate \
 --no-first-run --fast --fast-start --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
 --autoplay-policy=no-user-gesture-required --overscroll-history-navigation=0 \
 --password-store=basic --disable-features=Translate,InfiniteSessionRestore \
 --enable-features=OverlayScrollbar ${GPU_FLAG} ${MEDIA_FLAG} \
 --user-data-dir=\${PROFILE_DIR} --app=\${KIOSK_URL}"

while true; do
  rm -f "\${PROFILE_DIR}/SingletonLock" "\${PROFILE_DIR}/SingletonCookie" 2>/dev/null || true
  "\${CHROME_BIN}" \${CHROME_FLAGS} &
  CH_PID=\$!
  wait \$CH_PID
  echo "[kiosk.sh] Chromium dog (kod \$?) – omstart om 2s..."
  sleep 2
done
EOF
chown "${PI_USER}:${PI_USER}" "${KIOSK_SH}"
chmod +x "${KIOSK_SH}"

# ======= ENHANCED WATCHDOG: process + Aw Snap + vit/svart ruta =======
cat > "${WATCHDOG_SH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY=":0"
XAUTHORITY="$HOME/.Xauthority"
export DISPLAY XAUTHORITY

SNAP_PATTERNS=("Aw, Snap!" "He's dead, Jim!" "Åh nej!" "Oh no!")
NO_WIN_TIMEOUT=30           # om inget Chromium-fönster hittas på >30s -> omstart
MISSING_SINCE=0

SNAPSHOT_INTERVAL=30        # sekunder mellan skärmdumpskontroller
LAST_SNAPSHOT_CHECK=0
SUSPECT_COUNT=0             # hur många gånger i rad vi sett vit/svart bild
SUSPECT_LIMIT=3             # efter t.ex. 3 mätningar i rad -> omstart
SNAPSHOT_FILE="/tmp/kiosk_watchdog_capture.png"

have_imagemagick() {
  command -v import >/dev/null 2>&1 && command -v convert >/dev/null 2>&1
}

while true; do
  WIN_IDS=$(xdotool search --onlyvisible --class "chromium-browser" 2>/dev/null || \
            xdotool search --onlyvisible --class "chromium" 2>/dev/null || true)

  if [ -z "${WIN_IDS}" ]; then
    # Inget Chromium-fönster – mät hur länge
    if [ "$MISSING_SINCE" -eq 0 ]; then
      MISSING_SINCE=$(date +%s)
    else
      NOW=$(date +%s)
      if (( NOW - MISSING_SINCE > NO_WIN_TIMEOUT )); then
        echo "[watchdog] Inget Chromium-fönster > ${NO_WIN_TIMEOUT}s -> omstart"
        pkill -f chromium || pkill -f chromium-browser || true
        sleep 3
        MISSING_SINCE=0
        SUSPECT_COUNT=0
      fi
    fi
    sleep 5
    continue
  fi

  # Fönster finns – nollställ "missing"
  MISSING_SINCE=0

  WIN_ID=$(echo "${WIN_IDS}" | head -n1)
  TITLE=$(xdotool getwindowname "${WIN_ID}" 2>/dev/null || echo "")

  # 1) Titta på titel för kända felrutor (Aw, Snap mm)
  for p in "${SNAP_PATTERNS[@]}"; do
    if [[ "${TITLE}" == *"${p}"* ]]; then
      echo "[watchdog] Upptäckte felruta '${p}' (titel: '${TITLE}') -> omstart"
      pkill -f chromium || pkill -f chromium-browser || true
      sleep 3
      SUSPECT_COUNT=0
      continue 2
    fi
  done

          # 2) Vit/svart-rute-detektering via skärmdump (om ImageMagick finns)
          if have_imagemagick; then
            NOW=$(date +%s)
            if (( NOW - LAST_SNAPSHOT_CHECK >= SNAPSHOT_INTERVAL )); then
              LAST_SNAPSHOT_CHECK=$NOW

        # Ta en nedskalad skärmdump för att minimera CPU-last
        if import -silent -window "${WIN_ID}" -resize 320x180 "${SNAPSHOT_FILE}" >/dev/null 2>&1; then
          mean=$(convert "${SNAPSHOT_FILE}" -colorspace Gray -format "%[fx:mean]" info: 2>/dev/null || echo "")
          if [[ -n "${mean}" ]]; then
            # mean är ett flyttal 0..1 där 0=svart, 1=vit
            if awk -v m="${mean}" 'BEGIN{exit !(m>=0.97)}'; then
              # Nästan helt vit bild
              ((SUSPECT_COUNT++))
              echo "[watchdog] Misstänkt vit ruta (mean=${mean}, count=${SUSPECT_COUNT}/${SUSPECT_LIMIT})"
            else
              SUSPECT_COUNT=0
            fi
          fi
        fi
    fi
  fi

  sleep 10
done
EOF
chown "${PI_USER}:${PI_USER}" "${WATCHDOG_SH}"
chmod +x "${WATCHDOG_SH}"

# ======= systemd-tjänster =======
KIOSK_SERVICE="/etc/systemd/system/kiosk.service"
cat > "${KIOSK_SERVICE}" <<EOF
[Unit]
Description=Chromium Kiosk
Wants=graphical.target
After=graphical.target network-online.target

[Service]
User=${PI_USER}
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
Type=simple
ExecStart=${KIOSK_SH}
Restart=always
RestartSec=2
# Större /dev/shm motverkar "Aw, Snap!" vid minnesbrist
TemporaryFileSystem=/dev/shm:rw,nosuid,nodev,mode=1777,size=128M
KillMode=control-group

[Install]
WantedBy=graphical.target
EOF

WATCHDOG_SERVICE="/etc/systemd/system/chrome-watchdog.service"
cat > "${WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=Chromium Watchdog (enhanced)
After=kiosk.service
Requires=kiosk.service

[Service]
User=${PI_USER}
Type=simple
ExecStart=${WATCHDOG_SH}
Restart=always
RestartSec=2
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority

[Install]
WantedBy=graphical.target
EOF

# (Valfritt) Daglig soft reload 04:30
REFRESH_SERVICE="/etc/systemd/system/kiosk-refresh.service"
REFRESH_TIMER="/etc/systemd/system/kiosk-refresh.timer"
cat > "${REFRESH_SERVICE}" <<EOF
[Unit]
Description=Kiosk soft reload

[Service]
User=${PI_USER}
Type=oneshot
Environment=DISPLAY=:0
Environment=XAUTHORITY=${USER_HOME}/.Xauthority
ExecStart=/bin/bash -lc 'xdotool search --onlyvisible --class "chromium-browser" windowactivate --sync key F5 || xdotool search --onlyvisible --class "chromium" windowactivate --sync key F5'
EOF

cat > "${REFRESH_TIMER}" <<'EOF'
[Unit]
Description=Daily kiosk refresh at 04:30

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
Unit=kiosk-refresh.service

[Install]
WantedBy=timers.target
EOF

# ======= Aktivera =======
systemctl daemon-reload
systemctl enable kiosk.service chrome-watchdog.service
systemctl restart kiosk.service chrome-watchdog.service

if $ENABLE_REFRESH_TIMER; then
  systemctl enable --now kiosk-refresh.timer
else
  systemctl disable --now kiosk-refresh.timer >/dev/null 2>&1 || true
fi

echo
echo "==> KLART!"
echo "   Status:"
echo "     systemctl status kiosk.service"
echo "     systemctl status chrome-watchdog.service"
$ENABLE_REFRESH_TIMER && echo "     systemctl status kiosk-refresh.timer"
echo
echo "   Ändra URL:"
echo "     sudo sed -i \"s#^KIOSK_URL=.*#KIOSK_URL=\\\"${KIOSK_URL}\\\"#\" ${KIOSK_SH} && sudo systemctl restart kiosk.service"
