#!/usr/bin/env bash
# Wrapper che avvia MT5 e lo chiude in modo pulito su SIGTERM,
# dando tempo di salvare profili/chart prima dello shutdown del container.

export WINEPREFIX=/config/.wine
export WINEDEBUG=-all
export DISPLAY=:0
export WINEDLLOVERRIDES="mscoree,mshtml="

MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"

wine "$MT5_EXE" &
MT5_PID=$!

graceful_shutdown() {
    echo "[run_mt5] SIGTERM received — closing MT5 gracefully..."
    wine cmd /c taskkill /IM terminal64.exe 2>/dev/null || true
    # Attendi fino a 25 secondi che MT5 salvi e esca
    for i in $(seq 1 25); do
        kill -0 $MT5_PID 2>/dev/null || break
        sleep 1
    done
    echo "[run_mt5] MT5 closed."
}

trap graceful_shutdown TERM INT

wait $MT5_PID
