#!/usr/bin/env python3
"""
ScalpEngine v3 — Live Trade Monitor
Reads today's MT5 log, auto-detects active pairs, fetches live prices, shows P&L.
Run: python3 monitor.py
"""

import os
import re
import subprocess
import time
from datetime import datetime, date

try:
    import yfinance as yf
except ImportError:
    print("Run: pip install yfinance")
    exit(1)

CONTAINER  = "mt5-docker-mt5-1"
LOG_DIR_CT = "/config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Logs"


# ── Symbol helpers (no hardcoding) ──────────────────────────────────────────

def is_jpy_pair(sym: str) -> bool:
    return sym.upper().endswith("JPY")

def pip_size(sym: str) -> float:
    return 0.01 if is_jpy_pair(sym) else 0.0001

def symbol_to_ticker(sym: str) -> str:
    """EURUSD → EURUSD=X  (works for all standard forex pairs on yfinance)."""
    return sym.upper() + "=X"

def quote_currency(sym: str) -> str:
    """Last 3 chars of a 6-char forex symbol."""
    return sym.upper()[-3:]

def pip_value_eur(sym: str, price_diff: float, lots: float, prices: dict) -> float:
    """
    Compute floating P&L in EUR.
    pip_qty = how many units of quote currency per pip per lot
      - JPY pairs: 0.01 * 100_000 = 1000 JPY
      - others:    0.0001 * 100_000 = 10 quote units
    Then convert quote units → EUR via live rate.
    """
    ps   = pip_size(sym)
    pips = price_diff / ps
    qc   = quote_currency(sym)

    if qc == "EUR":
        rate = 1.0
    elif qc == "USD":
        rate = 1.0 / prices.get("EURUSD", 1.1)
    elif qc == "JPY":
        rate = 1.0 / prices.get("EURJPY", 160.0)
    elif qc == "CHF":
        rate = 1.0 / prices.get("EURCHF", 0.93)
    elif qc == "GBP":
        rate = 1.0 / prices.get("EURGBP", 0.85)
    elif qc == "AUD":
        rate = 1.0 / prices.get("EURAUD", 1.75)
    elif qc == "NZD":
        rate = 1.0 / prices.get("EURNZD", 1.90)
    elif qc == "CNH":
        rate = 1.0 / prices.get("EURCNH", 8.0)
    else:
        rate = 1.0 / prices.get(f"EUR{qc}", 1.0)

    pip_qty = (0.01 if is_jpy_pair(sym) else 0.0001) * 100_000
    return pips * pip_qty * rate * lots


def extract_symbols(lines: list) -> set:
    """Pull every symbol seen in ScalpEngine log lines."""
    sym_re = re.compile(r'ScalpEngine_v3 \(([A-Z]{6}),M5\)')
    return {m.group(1) for line in lines for m in sym_re.finditer(line)}


def eur_cross_symbols(active_symbols: set) -> set:
    """
    Return EUR cross tickers needed to convert pip values to EUR.
    e.g. if USDJPY is active we need EURJPY to convert JPY→EUR.
    """
    needed = set()
    for sym in active_symbols:
        qc = quote_currency(sym)
        if qc == "EUR":
            continue
        cross = f"EUR{qc}"
        if cross not in active_symbols:
            needed.add(cross)
    return needed


# ── Log reading ──────────────────────────────────────────────────────────────

def today_log():
    log_path = f"{LOG_DIR_CT}/{date.today().strftime('%Y%m%d')}.log"
    try:
        result = subprocess.run(
            ["docker", "exec", CONTAINER, "cat", log_path],
            capture_output=True, timeout=10
        )
        if result.returncode != 0:
            return [], None
        raw = result.stdout
    except Exception as e:
        return [], str(e)
    try:
        text = raw.decode("utf-16-le", errors="ignore")
    except Exception:
        text = raw.decode("utf-8", errors="ignore")
    lines = text.splitlines()
    if lines and lines[0].startswith('﻿'):
        lines[0] = lines[0][1:]
    return lines, None


def parse_trades(lines):
    open_pos = {}
    closed   = []

    entry_re = re.compile(
        r'(\d{2}:\d{2}:\d{2}).*ScalpEngine_v3 \((\w+),M5\).*'
        r'\[ENTRY\].*?(BUY|SELL) @ ([\d.]+).*SL: ([\d.]+).*TP: ([\d.]+).*lots: ([\d.]+)'
    )
    exit_re = re.compile(
        r'(\d{2}:\d{2}:\d{2}).*ScalpEngine_v3 \((\w+),M5\).*'
        r'\[EXIT\].*profit: ([+-]?[\d.]+)'
    )
    reason_re = re.compile(r'(TAKE PROFIT|STOP LOSS|closed externally|session)')

    for line in lines:
        m = entry_re.search(line)
        if m:
            t, sym, direction, entry, sl, tp, lots = m.groups()
            open_pos[sym] = {
                "dir": direction, "entry": float(entry),
                "sl": float(sl), "tp": float(tp), "lots": float(lots), "time": t
            }
            continue
        m = exit_re.search(line)
        if m:
            t, sym, pnl = m.groups()
            rm = reason_re.search(line)
            closed.append({"symbol": sym, "pnl": float(pnl),
                           "reason": rm.group(1) if rm else "closed", "time": t})
            open_pos.pop(sym, None)

    return open_pos, closed


def parse_activity(lines):
    activity = []
    ts_re    = re.compile(r'(\d{2}:\d{2}:\d{2})')
    keywords = ("[CONFIG]", "Entry blocked", "[REGIME]", "[DIV]", "[ENTRY]", "[EXIT]")
    for line in lines:
        if any(k in line for k in keywords):
            m   = ts_re.search(line)
            t   = m.group(1) if m else "??:??:??"
            parts = line.split('\t')
            msg = parts[-1][:80] if len(parts) >= 2 else line[:80]
            ea_m = re.search(r'ScalpEngine_v3 \((\w+),M5\)', line)
            sym  = ea_m.group(1) if ea_m else "????"
            activity.append(f"  {t}  {sym:<8} {msg}")
    return activity[-6:]


def get_log_timestamp(lines):
    ts_re = re.compile(r'(\d{2}:\d{2}:\d{2})')
    for line in reversed(lines):
        m = ts_re.search(line)
        if m:
            return m.group(1)
    return None


# ── Price fetching ───────────────────────────────────────────────────────────

def get_prices(symbols: set) -> dict:
    """Fetch latest 1-min close for each symbol. symbols may include EUR crosses."""
    prices = {}
    for sym in symbols:
        ticker = symbol_to_ticker(sym)
        try:
            df = yf.download(ticker, period="1d", interval="1m",
                             progress=False, auto_adjust=True)
            if not df.empty:
                prices[sym] = float(df["Close"].squeeze().iloc[-1])
        except Exception:
            pass
    return prices


# ── Display ──────────────────────────────────────────────────────────────────

def color(val, text=None):
    t = text if text is not None else f"{val:+.2f}"
    if val > 0:  return f"\033[92m{t}\033[0m"
    if val < 0:  return f"\033[91m{t}\033[0m"
    return f"\033[93m{t}\033[0m"


# ── Main loop ────────────────────────────────────────────────────────────────

def run():
    while True:
        os.system("clear")
        now = datetime.now().strftime("%H:%M:%S")
        lines, err = today_log()

        if err or not lines:
            print(f"\033[91m ScalpEngine v3 — Monitor  {now}\033[0m")
            print(f"  ERROR reading log: {err or 'no lines'}")
            time.sleep(30)
            continue

        open_pos, closed = parse_trades(lines)
        last_log_ts      = get_log_timestamp(lines)

        # Auto-detect all symbols active today
        all_syms = extract_symbols(lines)
        # Symbols we need prices for: open positions + EUR crosses for conversion
        price_syms = set(open_pos.keys()) | eur_cross_symbols(set(open_pos.keys()))
        prices     = get_prices(price_syms) if price_syms else {}

        # Closed P&L
        closed_by_sym = {}
        for c in closed:
            closed_by_sym[c["symbol"]] = closed_by_sym.get(c["symbol"], 0) + c["pnl"]
        total_closed = sum(closed_by_sym.values())

        # Floating P&L
        floating = {}
        for sym, pos in open_pos.items():
            if sym not in prices:
                floating[sym] = 0.0
                continue
            now_price = prices[sym]
            sign      = 1 if pos["dir"] == "BUY" else -1
            diff      = (now_price - pos["entry"]) * sign
            floating[sym] = pip_value_eur(sym, diff, pos.get("lots", 1.0), prices)

        total_float  = sum(floating.values())
        total_day    = total_closed + total_float
        total_trades = len(closed)
        wins         = sum(1 for c in closed if c["pnl"] > 0)
        win_rate     = (wins / total_trades * 100) if total_trades else 0

        # ── Header ──────────────────────────────────────────────────────
        log_age = f"  log UTC: {last_log_ts}" if last_log_ts else ""
        n_pairs = len(all_syms)
        print(f"\033[1m ScalpEngine v3 — Live Monitor  {now}{log_age}  [{n_pairs} pairs]\033[0m")
        print("─" * 70)

        # ── Open positions ───────────────────────────────────────────────
        if open_pos:
            print(f"\033[1m OPEN POSITIONS\033[0m")
            print(f"  {'Sym':<8}{'Dir':<6}{'Entry':>10}{'Now':>10}{'SL':>10}  {'Float':>8}  {'→SL':>6}")
            print("  " + "─" * 58)
            for sym, pos in open_pos.items():
                now_p   = prices.get(sym, 0)
                ps      = pip_size(sym)
                sl_dist = abs(now_p - pos["sl"]) / ps if now_p else 0
                fl      = floating.get(sym, 0)
                warn    = " ⚠" if sl_dist < 50 else ""
                decimals = 3 if is_jpy_pair(sym) else 5
                fmt = f"{{:>10.{decimals}f}}"
                print(f"  {sym:<8}{pos['dir']:<6}"
                      f"{fmt.format(pos['entry'])}{fmt.format(now_p)}{fmt.format(pos['sl'])}  "
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

        # ── Recent EA activity ───────────────────────────────────────────
        print()
        print(f"\033[1m RECENT ACTIVITY  ({len(lines)} log lines)\033[0m")
        for a in parse_activity(lines):
            print(a)

        # ── Summary ──────────────────────────────────────────────────────
        print()
        print("─" * 70)
        print(f"  Closed:   {color(total_closed, f'{total_closed:+.2f} EUR')}")
        print(f"  Floating: {color(total_float,  f'{total_float:+.2f} EUR')}")
        print(f"  \033[1mTODAY:    {color(total_day, f'{total_day:+.2f} EUR')}\033[0m")

        if total_float < -200:
            print()
            print(f"\033[91;1m ⚠  ALERT: floating loss {total_float:+.0f} EUR — CHECK POSITIONS MANUALLY\033[0m")
            print("\a", end="", flush=True)

        print("─" * 70)
        print(f"  \033[90mRefresh in 60s — Ctrl+C to quit\033[0m")

        time.sleep(60)


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        print("\nMonitor stopped.")
