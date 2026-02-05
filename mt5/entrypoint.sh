#!/usr/bin/env bash
set -euo pipefail

export WINEPREFIX=/config/.wine
export WINEDEBUG=-all

MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
INSTALLER="/root/mt5setup.exe"

if [ ! -d "$WINEPREFIX" ]; then
  mkdir -p "$WINEPREFIX"
  wineboot -u || true
fi

if [ ! -f "$MT5_EXE" ]; then
  echo "[entrypoint] MT5 not found, installing (may need manual via VNC)..."
  timeout 600 xvfb-run -a wine "$INSTALLER" /auto || true
  if [ ! -f "$MT5_EXE" ]; then
    echo "[entrypoint] MT5 still not detected. Open VNC and run:"
    echo "  wine C:\\\\mt5setup.exe"
  fi
else
  echo "[entrypoint] MT5 already installed."
fi

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
