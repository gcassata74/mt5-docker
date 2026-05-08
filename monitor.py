#!/usr/bin/env python3
"""
RSI Engine v2.2 — Live Trade Monitor
Reads today's MT5 log, detects open positions, fetches live prices, shows P&L.
Run: python3 monitor.py
"""

import os
import re
import time
from datetime import datetime, date
from pathlib import Path

try:
    import yfinance as yf
except ImportError:
    print("Run: pip install yfinance")
    exit(1)

LOG_DIR = Path(__file__).parent / "mt5" / "logs"

TICKERS = {
    "EURUSD": "EURUSD=X",  "USDJPY": "USDJPY=X",
    "USDCHF": "USDCHF=X",  "AUDUSD": "AUDUSD=X",
    "GBPUSD": "GBPUSD=X",  "EURJPY": "EURJPY=X",
    "EURGBP": "EURGBP=X",  "USDCNH": "USDCNH=X",
}

PIP_EUR = {
    "EURUSD": 10.0, "GBPUSD": 10.0, "AUDUSD": 6.4,
    "USDCHF": 11.0, "USDJPY": 6.4,  "EURJPY": 6.4,
    "EURGBP": 12.0, "USDCNH": 1.4,
}

JPY_PAIRS = {"USDJPY", "EURJPY"}

MAGIC_SYMBOLS = {
    "220001": "EURUSD", "220002": "AUDUSD", "220003": "USDCHF",
    "220004": "GBPUSD", "220005": "USDJPY", "220006": "EURJPY",
    "220007": "USDCNH", "220008": "EURGBP",
}


def today_log():
    path = LOG_DIR / f"{date.today().strftime('%Y%m%d')}.log"
    if not path.exists():
        return []
    with open(path, "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-16-le", errors="ignore")
    except Exception:
        text = raw.decode("utf-8", errors="ignore")
    return text.splitlines()


def parse_trades(lines):
    """Returns (open_positions, closed_pnl_by_symbol, all_closed)."""
    open_pos = {}   # symbol -> {dir, entry, sl, tp, time}
    closed = []     # list of {symbol, pnl, reason, time}

    entry_re = re.compile(
        r'(\d{2}:\d{2}:\d{2}).*The_RSI_Engine_v2\.2 \((\w+),M5\).*'
        r'\[(?:ENTRY|DIV)\].*?(BUY|SELL) @ ([\d.]+).*SL: ([\d.]+).*TP: ([\d.]+)'
    )
    exit_re = re.compile(
        r'(\d{2}:\d{2}:\d{2}).*The_RSI_Engine_v2\.2 \((\w+),M5\).*'
        r'\[EXIT\].*profit: ([+-]?[\d.]+) EUR'
    )
    exit_reason_re = re.compile(r'(TAKE PROFIT|STOP LOSS|closed externally|session)')

    for line in lines:
        m = entry_re.search(line)
        if m:
            t, sym, direction, entry, sl, tp = m.groups()
            open_pos[sym] = {
                "dir": direction, "entry": float(entry),
                "sl": float(sl), "tp": float(tp), "time": t
            }
            continue

        m = exit_re.search(line)
        if m:
            t, sym, pnl = m.groups()
            reason_m = exit_reason_re.search(line)
            reason = reason_m.group(1) if reason_m else "closed"
            closed.append({"symbol": sym, "pnl": float(pnl), "reason": reason, "time": t})
            open_pos.pop(sym, None)

    return open_pos, closed


def get_prices(symbols):
    prices = {}
    for sym in symbols:
        ticker = TICKERS.get(sym)
        if not ticker:
            continue
        try:
            df = yf.download(ticker, period="1d", interval="1m",
                             progress=False, auto_adjust=True)
            if not df.empty:
                prices[sym] = float(df["Close"].squeeze().iloc[-1])
        except Exception:
            pass
    return prices


def pip_value(sym, price_diff):
    div = 0.01 if sym in JPY_PAIRS else 0.0001
    return (price_diff / div) * PIP_EUR.get(sym, 10.0)


def color(val, text=None):
    t = text if text is not None else f"{val:+.2f}"
    if val > 0:   return f"\033[92m{t}\033[0m"
    if val < 0:   return f"\033[91m{t}\033[0m"
    return f"\033[93m{t}\033[0m"


def run():
    while True:
        os.system("clear")
        now = datetime.now().strftime("%H:%M:%S")
        lines = today_log()
        open_pos, closed = parse_trades(lines)

        # Closed P&L per symbol (sum over day)
        closed_by_sym = {}
        for c in closed:
            closed_by_sym[c["symbol"]] = closed_by_sym.get(c["symbol"], 0) + c["pnl"]
        total_closed = sum(closed_by_sym.values())

        # Fetch live prices for open positions
        prices = get_prices(list(open_pos.keys())) if open_pos else {}

        # Floating P&L
        floating = {}
        for sym, pos in open_pos.items():
            if sym not in prices:
                floating[sym] = 0.0
                continue
            now_price = prices[sym]
            sign = 1 if pos["dir"] == "BUY" else -1
            diff = (now_price - pos["entry"]) * sign
            floating[sym] = pip_value(sym, diff)

        total_float  = sum(floating.values())
        total_day    = total_closed + total_float
        total_trades = len(closed)
        wins         = sum(1 for c in closed if c["pnl"] > 0)
        win_rate     = (wins / total_trades * 100) if total_trades else 0

        # ── Header ──────────────────────────────────────────────────────
        print(f"\033[1m RSI Engine v2.2 — Live Monitor  {now}\033[0m")
        print("─" * 62)

        # ── Open positions ───────────────────────────────────────────────
        if open_pos:
            print(f"\033[1m OPEN POSITIONS\033[0m")
            print(f"  {'Sym':<8}{'Dir':<6}{'Entry':>10}{'Now':>10}{'SL':>10}  {'Float':>8}  {'→SL':>6}")
            print("  " + "─" * 58)
            for sym, pos in open_pos.items():
                now_p = prices.get(sym, 0)
                div   = 0.01 if sym in JPY_PAIRS else 0.0001
                sl_dist = abs(now_p - pos["sl"]) / div if now_p else 0
                fl    = floating.get(sym, 0)
                warn  = " ⚠" if sl_dist < 50 else ""
                print(f"  {sym:<8}{pos['dir']:<6}{pos['entry']:>10.5f}"
                      f"{now_p:>10.5f}{pos['sl']:>10.5f}  "
                      f"{color(fl, f'{fl:+.1f}'):>17}  {sl_dist:>4.0f}p{warn}")
        else:
            print("  \033[90mNo open positions\033[0m")

        # ── Closed trades today ──────────────────────────────────────────
        print()
        print(f"\033[1m CLOSED TODAY  ({total_trades} trades, {win_rate:.0f}% win rate)\033[0m")
        if closed_by_sym:
            for sym, pnl in sorted(closed_by_sym.items()):
                bar = "▪" * min(int(abs(pnl) / 20), 20)
                print(f"  {sym:<8}  {color(pnl, f'{pnl:+.2f} EUR'):<24}  {bar}")
        else:
            print("  \033[90mNo closed trades yet\033[0m")

        # ── Summary ──────────────────────────────────────────────────────
        print()
        print("─" * 62)
        print(f"  Closed:   {color(total_closed, f'{total_closed:+.2f} EUR')}")
        print(f"  Floating: {color(total_float,  f'{total_float:+.2f} EUR')}")
        print(f"  \033[1mTODAY:    {color(total_day, f'{total_day:+.2f} EUR')}\033[0m")
        # ── Auto-alert ───────────────────────────────────────────────
        ALERT_THRESHOLD = -200  # EUR floating loss → trigger warning
        if total_float < ALERT_THRESHOLD:
            print()
            print(f"\033[91;1m ⚠  ALERT: floating loss {total_float:+.0f} EUR — CHECK POSITIONS MANUALLY\033[0m")
            print("\a", end="", flush=True)  # terminal bell

        print("─" * 62)
        print(f"  \033[90mRefresh in 10min — Ctrl+C to quit\033[0m")

        time.sleep(600)


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        print("\nMonitor stopped.")
