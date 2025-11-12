#!/usr/bin/env bash

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

if grep -q $'\r' "$0"; then
  echo "[setup-kiosk] Upptäckte Windows-radslut (CRLF) – fixar..."
  tmp="$(mktemp)"
  tr -d '\r' < "$0" > "$tmp"
  chmod +x "$tmp"
  exec bash "$tmp" "$@"
fi

# --- Auto-sudo: höj behörighet om vi inte är root ---
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

# ======= Standardvärden =======
KIOSK_URL="https://int1.visitlinkoping.se/spot"
PI_USER="${SUDO_USER:-${USER:-pi}}"
DISABLE_GPU=false
ENABLE_REFRESH_TIMER=true

# ======= Argument =======
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) KIOSK_URL="$2"; shift 2 ;;
    --user) PI_USER="$2"; shift 2 ;;
    --disable-gpu) DISABLE_GPU=true; shift ;;
    --no-refresh) ENABLE_REFRESH_TIMER=false; shift ;;
    *) echo "Okänt argument: $1"; exit 1 ;;
  endcase
done

echo "==> Installerar kiosk"
echo "    Användare: ${PI_USER}"
echo "    URL:       ${KIOSK_URL}"
echo "    Disable GPU: ${DISABLE_GPU}"
echo "    Daglig soft refresh 04:30: ${ENABLE_REFRESH_TIMER}"

# ======= Kontroller =======
if ! id -u "${PI_USER}" >/dev/null 2>&1; then
  echo "Användaren ${PI_USER} finns inte."; exit 1
fi

USER_HOME=$(eval echo "~${PI_USER}")

if ! command -v raspi-config >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y raspi-config || true
fi

if command -v raspi-config >/dev/null 2>&1; then
  echo "==> Sätter autologin till Desktop (raspi-config B4)…"
  raspi-config nonint do_boot_behaviour B4 || true
  echo "==> Försöker växla till X11 (bort från Wayland)…"
  # Vissa images har denna växel, andra ignorerar bara kommandot.
  raspi-config nonint do_wayland 1 || true
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y xdotool unclutter coreutils sed dbus-x11

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

# ======= Kiosk- och watchdog-script =======
PROFILE_DIR="${USER_HOME}/.config/chromium"
KIOSK_SH="${USER_HOME}/kiosk.sh"
WATCHDOG_SH="${USER_HOME}/chrome_watchdog.sh"

GPU_FLAG=""
$DISABLE_GPU && GPU_FLAG="--disable-gpu --disable-accelerated-2d-canvas"

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
 --enable-features=OverlayScrollbar ${GPU_FLAG} \
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

cat > "${WATCHDOG_SH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY=":0"
XAUTHORITY="$HOME/.Xauthority"
export DISPLAY XAUTHORITY

SNAP_PATTERNS=("Aw, Snap!" "He's dead, Jim!" "Åh nej!" "Oh no!")
BLANK_HANG_SECONDS=60
LAST_TITLE=""
LAST_CHANGE=$(date +%s)

while true; do
  WIN_IDS=$(xdotool search --onlyvisible --class "chromium-browser" 2>/dev/null || \
            xdotool search --onlyvisible --class "chromium" 2>/dev/null || true)
  if [ -z "${WIN_IDS}" ]; then
    sleep 10
    continue
  fi
  WIN_ID=$(echo "${WIN_IDS}" | head -n1)
  TITLE=$(xdotool getwindowname "${WIN_ID}" 2>/dev/null || echo "")

  for p in "${SNAP_PATTERNS[@]}"; do
    if [[ "${TITLE}" == *"${p}"* ]]; then
      echo "[watchdog] Hittade '${p}' -> omstart"
      pkill -f chromium || pkill -f chromium-browser || true
      sleep 3
      break
    fi
  done

  NOW=$(date +%s)
  if [[ -n "${TITLE}" && "${TITLE}" != "${LAST_TITLE}" ]]; then
    LAST_TITLE="${TITLE}"
    LAST_CHANGE="${NOW}"
  fi
  if (( NOW - LAST_CHANGE > BLANK_HANG_SECONDS )); then
    echo "[watchdog] Titel oförändrad > ${BLANK_HANG_SECONDS}s ('${TITLE}') -> omstart"
    pkill -f chromium || pkill -f chromium-browser || true
    sleep 3
    LAST_CHANGE="${NOW}"
    LAST_TITLE=""
  fi
  sleep 15
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
# Öka /dev/shm – motverkar "Aw, Snap!" vid minnesbrist
TemporaryFileSystem=/dev/shm:rw,nosuid,nodev,mode=1777,size=128M
KillMode=control-group

[Install]
WantedBy=graphical.target
EOF

WATCHDOG_SERVICE="/etc/systemd/system/chrome-watchdog.service"
cat > "${WATCHDOG_SERVICE}" <<EOF
[Unit]
Description=Chromium Watchdog
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

# (Valfritt) Daglig soft refresh
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
echo "   Ändra URL framöver:"
echo "     sudo sed -i \"s#^KIOSK_URL=.*#KIOSK_URL=\\\"${KIOSK_URL}\\\"#\" ${KIOSK_SH} && sudo systemctl restart kiosk.service"

