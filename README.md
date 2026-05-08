# MT5 Docker + RSI Engine v2.2

MetaTrader 5 running inside a Docker container (Wine + noVNC), with the **RSI Engine v2.2** Expert Advisor — a dual-mode scalping strategy for M5 forex pairs.

---

## Table of Contents

1. [Infrastructure](#infrastructure)
2. [Trading Strategy](#trading-strategy)
   - [Regime Detection (ADX)](#1-regime-detection-adx)
   - [Ranging Mode — RSI(2) Mean Reversion](#2-ranging-mode--rsi2-mean-reversion)
   - [Trending Mode — Hidden Divergence](#3-trending-mode--hidden-divergence)
   - [EMA Trend Filter](#4-ema-trend-filter)
   - [Risk & Filters](#5-risk--filters)
3. [Why This Approach Works](#why-this-approach-works)
4. [Parameter Reference](#parameter-reference)
5. [Symbol Presets](#symbol-presets)
6. [Reading the Logs](#reading-the-logs)
7. [Going Live](#going-live)
8. [Docker Quick Reference](#docker-quick-reference)

---

## Infrastructure

MetaTrader 5 runs under Wine inside a Docker container. A noVNC web server exposes the MT5 GUI directly in the browser — no Windows machine needed.

**Requirements:** Docker Engine, Docker Compose v2

```bash
# Start
docker compose up --build

# Access MT5
http://localhost:8000   # noVNC browser UI
localhost:1234          # VNC client (optional)

# Stop
docker compose down
```

**Persistent mounts:**

| Host path | Container path | Purpose |
|---|---|---|
| `./mt5/experts/` | MT5 Experts Downloads | EA source files (`.mq5`) and compiled binaries (`.ex5`) |
| `./mt5/indicators/` | MT5 Indicators Downloads | Custom indicators |
| `./mt5/home/presets/` | `/home/presets/` | `.set` parameter files per symbol |
| `./mt5/logs/` | MT5 Logs | Daily log files (`YYYYMMDD.log`) |

**Compiling the EA:** open MetaEditor inside MT5 (Tools → MetaEditor), open `The_RSI_Engine_v2.2.mq5`, press **F7**. The `.ex5` binary is written automatically to the Experts folder.

---

## Trading Strategy

The RSI Engine v2.2 implements a **dual-mode scalping strategy** on M5 bars. On every new bar it first measures the market regime via ADX, then routes to the appropriate entry logic:

```
New bar
  │
  ├─ ADX < 30  →  RANGING regime  →  RSI(2) Mean Reversion
  └─ ADX ≥ 30  →  TRENDING regime →  Hidden Divergence
```

This regime-switching approach solves the core problem of RSI(2) strategies: mean reversion works well in sideways markets but produces losses in strong trends. By detecting the trend strength first, the EA adapts its logic automatically.

---

### 1. Regime Detection (ADX)

**ADX (Average Directional Index)** measures the *strength* of a trend, regardless of direction. It does not tell you whether the market is going up or down — only how directional the move is.

| ADX value | Market character | EA mode |
|---|---|---|
| < 20 | Flat, no trend | Ranging — mean reversion |
| 20–30 | Moderate trend | Ranging — mean reversion |
| ≥ 30 | Strong trend | Trending — hidden divergence |
| > 50 | Very strong trend | Trending — hidden divergence |

**Why ADX 30 as threshold:** backtesting on 30 days of M5 data across 5 pairs showed that ADX ≥ 30 signals account for ~20–28% of all bars but contain the majority of RSI(2) false reversals. Raising the threshold to 30 (from the classic 25) reduces signal blocking while still filtering the most dangerous trending conditions.

**Log output:**
```
[REGIME] Switched to TRENDING (ADX=38.4 >= 30) — hidden divergence mode
[REGIME] Switched to RANGING (ADX=24.1 < 30) — mean reversion mode
```
The regime log fires only on **change**, not on every bar, so it never spams.

---

### 2. Ranging Mode — RSI(2) Mean Reversion

When ADX < 30, the market is moving sideways and the EA uses **RSI(2) mean reversion**, a well-known approach popularised by Larry Connors.

**Core idea:** with a 2-bar RSI, the indicator swings violently between extremes (0–100) and reaches the oversold/overbought zones very frequently. When it crosses *back* out of an extreme, it signals the short-term overextension is resolving and the price is reverting toward the mean.

**Entry conditions (BUY):**
1. Previous bar: RSI(2) < 10 (extreme oversold)
2. Current bar: RSI(2) ≥ 10 (crossed back above threshold)
3. Current price > EMA(50) (uptrend — see EMA filter below)

**Entry conditions (SELL):**
1. Previous bar: RSI(2) > 90 (extreme overbought)
2. Current bar: RSI(2) ≤ 90 (crossed back below threshold)
3. Current price < EMA(50) (downtrend)

**Why RSI period 2:** longer periods (e.g. 14) take too long to reach extremes on M5, producing very few signals. Period 2 hits the 10/90 thresholds multiple times per day, enabling high-frequency scalping with small TP targets.

**Why only trade the crossback, not the extreme itself:** entering at the extreme (RSI = 5) means the short-term move may continue further before reversing. Waiting for the crossback confirms the reversal has started.

**Log output:**
```
[ENTRY] BUY @ 1.17650 | RSI: 8.2→11.4 | SL: 1.17450 | TP: 1.17800 | lots: 1.00
[ENTRY] SELL @ 156.780 | RSI: 93.8→28.9 | SL: 156.980 | TP: 156.630 | lots: 1.00
```

---

### 3. Trending Mode — Hidden Divergence

When ADX ≥ 30, mean reversion is dangerous — the trend is too strong and the price will not revert. Instead, the EA switches to **hidden divergence**, which trades *with* the trend by identifying pullbacks that are about to end.

**What is hidden divergence?**

Hidden divergence occurs when price and RSI move in opposite directions during a pullback within a trend. It signals that the pullback is temporary and the trend is about to resume.

**Hidden Bullish Divergence (uptrend, BUY):**
- The overall trend is up (price > EMA50)
- Price makes a **higher low** (the current pullback holds above the previous pullback)
- RSI(2) makes a **lower low** (RSI drops further than last time)
- Interpretation: the market is holding price up while RSI overshoots downward → the underlying trend is still strong → the trend will resume → BUY

```
Price:  ...low₁......................higher low₂....  ↑ trend intact
RSI:    ...low₁(35)..................lower low₂(18)..  ↓ overshoots
                                     ↑ enter BUY here
```

**Hidden Bearish Divergence (downtrend, SELL):**
- The overall trend is down (price < EMA50)
- Price makes a **lower high** (the bounce does not reach the previous bounce high)
- RSI(2) makes a **higher high** (RSI rallies further than last time)
- Interpretation: price is weakening on each bounce while RSI overshoots → the downtrend is intact → SELL

**Detection algorithm:**
1. Confirm trend direction via EMA50
2. Check RSI is in pullback zone: RSI < 40 for uptrend, RSI > 60 for downtrend
3. Look back `InpDivLookback` bars (default 20 bars = 100 minutes on M5)
4. Find the reference swing: lowest close in lookback (uptrend) or highest close (downtrend)
5. Compare current price and RSI against the reference swing
6. If divergence conditions are met, enter in the trend direction

**Log output:**
```
[DIV] HIDDEN BULL BUY @ 1.17413 | RSI: 31.9 < ref 93.5 (bar 20) | price: 1.17399 > ref 1.17311 | SL: 1.17213 | TP: 1.17563
[DIV] HIDDEN BEAR SELL @ 0.77927 | RSI: 80.2 > ref 48.3 (bar 20) | price: 0.77927 < ref 0.77995 | SL: 0.78127 | TP: 0.77777
[DIV] No hidden bull | RSI: 29.3 ref: 14.2 | price: 0.72306 ref: 0.72225
```

---

### 4. EMA Trend Filter

Both modes use an **EMA(50)** filter to ensure trades are aligned with the intraday trend direction.

- EMA(50) on M5 = ~4 hours of smoothed price history
- **BUY signals** are only taken when price is **above** EMA(50)
- **SELL signals** are only taken when price is **below** EMA(50)

EMA(50) was chosen over EMA(200) (which covers ~16 hours) because it reacts faster to intraday trend changes, reducing the lag that caused missed signals and wrong-direction trades in earlier versions.

**Log output (when blocked):**
```
Entry blocked: BUY signal but price (1.17612) below EMA (1.17682)
Entry blocked: SELL signal but price (156.587) above EMA (156.367)
```

---

### 5. Risk & Filters

#### Position Sizing
Fixed lot size per trade (default: 1.0 lot). On EURUSD, 1 lot = ~10 EUR/pip.

| Parameter | Default | Meaning |
|---|---|---|
| `InpLots` | 1.0 | Fixed lot size |
| `InpStopLossPoints` | 200 | 20 pips SL → ~200 EUR risk per trade on EURUSD |
| `InpTakeProfitPoints` | 150 | 15 pips TP → ~150 EUR profit per trade on EURUSD |

Risk:reward ratio is 1:0.75 intentionally — the high win rate of RSI(2) mean reversion compensates for the asymmetry.

#### Daily Limits
The EA tracks cumulative P&L per symbol per day and stops trading when limits are hit.

| Parameter | Default | Meaning |
|---|---|---|
| `DailyProfitTarget` | 300.0 EUR | Stop taking new trades once daily profit reaches this |
| `DailyLossLimit` | 150.0 EUR | Stop taking new trades once daily loss reaches this |

#### Spread Filter
New entries are blocked when the spread is too wide (slippage cost would erode the edge).

| Parameter | Default | Meaning |
|---|---|---|
| `InpMaxSpreadPoints` | 15 | ~1.5 pips max spread for entry |

#### Time Filter
Configurable trading sessions per day of week (server time). Default sessions avoid low-liquidity periods (Asia overnight, Friday close).

```
Monday–Thursday:  09:00–12:00, 14:00–21:00
Friday:           09:00–12:00, 14:00–20:00
Saturday/Sunday:  closed
```

`CloseAtEndTime=true` forces all positions closed at the end of each session.

#### News Filter
A configurable time window around a fixed daily news event blocks both new entries and (optionally) closes open positions.

| Parameter | Default | Meaning |
|---|---|---|
| `InpUseNewsFilter` | true | Enable news filter |
| `InpNewsTimeHour` | 15 | News event hour (server time) |
| `InpNewsTimeMinute` | 30 | News event minute |
| `InpMinutesBeforeNews` | 30 | Block entries 30 min before |
| `InpMinutesAfterNews` | 30 | Block entries 30 min after |
| `InpCloseBeforeNews` | true | Close open position before news window |

---

## Why This Approach Works

**Mean reversion (ranging markets):** RSI(2) is extremely sensitive and reaches oversold/overbought levels many times per day. In a sideways market, every spike away from the mean is a trading opportunity. The edge comes from the statistical tendency of short-term overextensions to revert. Larry Connors' research on RSI(2) shows win rates above 60–65% in ranging conditions.

**Hidden divergence (trending markets):** In a strong trend, mean reversion fails because the trend overpowers any short-term reversion. Hidden divergence solves this by identifying *pullbacks that are ending* — moments when the price pauses briefly but the trend structure is intact. The entry is taken with the trend, not against it.

**ADX regime switching:** the combination ensures the EA is never using the wrong strategy for the current market condition. Rather than blocking all activity during trends (which eliminates a large portion of trading time), it switches to a trend-following approach that profits from the same trending conditions that would have caused losses with pure mean reversion.

**Backtest results (30 days, 5 pairs, 1 lot):**

| Metric | Value |
|---|---|
| Total trades | ~406 |
| Win rate | 56% |
| Average daily P&L | ~152 EUR |
| Best day | +778 EUR |
| Worst day | -714 EUR (without daily limits) |
| Days above +200 EUR | 50% |
| Mean reversion trades | ~49% |
| Hidden divergence trades | ~51% |

*Note: backtest does not account for daily loss limits. With limits active, worst-day drawdown is significantly reduced.*

---

## Parameter Reference

Full parameter list for `The_RSI_Engine_v2.2.mq5`:

### Trade Management

| Parameter | Default | Description |
|---|---|---|
| `InpUseRiskManagement` | false | If true, lot size is calculated dynamically from `InpRiskPercent` |
| `InpRiskPercent` | 1.0 | % of account equity risked per trade (only used if risk management enabled) |
| `InpLots` | 1.0 | Fixed lot size (used when risk management is disabled) |
| `InpStopLossPoints` | 200 | Stop loss in points (200 points = 20 pips on 5-digit symbols) |
| `InpTakeProfitPoints` | 150 | Take profit in points (150 points = 15 pips) |
| `InpMagicNumber` | — | Unique identifier for this EA instance. Different per symbol. |
| `InpMaxSpreadPoints` | 15 | Maximum allowed spread at entry time |

### RSI Settings

| Parameter | Default | Description |
|---|---|---|
| `InpRSI_Period` | 2 | RSI period. 2 = ultra-fast, many signals, Larry Connors style |
| `InpRSI_Overbought` | 90 | Overbought level. SELL signal when RSI crosses back below this |
| `InpRSI_Oversold` | 10 | Oversold level. BUY signal when RSI crosses back above this |

### Strategy Filters

| Parameter | Default | Description |
|---|---|---|
| `InpUseEMAFilter` | true | Apply EMA trend filter to all signals |
| `InpEMA_Period` | 50 | EMA period for trend filter (~4 hours on M5) |
| `InpUseADXFilter` | true | Enable dual-mode regime switching |
| `InpADX_Period` | 14 | ADX calculation period |
| `InpADX_Threshold` | 30.0 | ADX above this triggers trending mode |

### Hidden Divergence Settings

| Parameter | Default | Description |
|---|---|---|
| `InpDivLookback` | 20 | Bars to look back for reference swing (20 bars = 100 min on M5) |
| `InpDivRSI_Pullback` | 40 | RSI must be below this level to confirm a pullback in uptrend |
| `InpDivRSI_Rally` | 60 | RSI must be above this level to confirm a rally in downtrend |

### Daily Limits

| Parameter | Default | Description |
|---|---|---|
| `EnableDailyLimits` | true | Enable daily stop rules |
| `DailyProfitTarget` | 300.0 | Stop new entries when cumulative daily profit reaches this (EUR) |
| `DailyLossLimit` | 150.0 | Stop new entries when cumulative daily loss reaches this (EUR) |

---

## Symbol Presets

Each symbol has a dedicated `.set` file in `mt5/home/presets/`. Magic numbers are unique per symbol to allow running multiple instances simultaneously.

| Symbol | File | Magic Number | Notes |
|---|---|---|---|
| EURUSD | `EURUSD_M5.set` | 220001 | Primary pair, 10 EUR/pip at 1 lot |
| AUDUSD | `AUDUSD_M5.set` | 220002 | ~6.4 EUR/pip at 1 lot |
| USDCHF | `USDCHF_M5.set` | 220003 | ~11 EUR/pip at 1 lot |
| GBPUSD | `GBPUSD_M5.set` | 220004 | 10 EUR/pip at 1 lot |
| USDJPY | `USDJPY_M5.set` | 220005 | ~6.4 EUR/pip at 1 lot |
| EURJPY | `EURJPY_M5.set` | 220006 | |
| USDCNH | `USDCNH_M5.set` | 220007 | Lower liquidity |
| EURGBP | `EURGBP_M5.set` | 220008 | |

**Loading a preset in MT5:**
1. Drag the EA onto the chart for the desired symbol (M5 timeframe)
2. In the EA settings dialog, click **Load** and select the corresponding `.set` file
3. Enable AutoTrading (the button in the MT5 toolbar must be green)

---

## Reading the Logs

Logs are written to `mt5/logs/YYYYMMDD.log`. Key tags:

| Tag | Meaning |
|---|---|
| `[REGIME]` | Market regime changed (RANGING ↔ TRENDING). Fires only on change. |
| `[ENTRY]` | New trade opened (mean reversion mode) |
| `[DIV]` | New trade opened or skipped (hidden divergence mode) |
| `[EXIT]` | Trade closed (SL, TP, or session end) |
| `[PNL]` | Per-trade and cumulative daily P&L |
| `[LIMIT]` | Daily profit or loss limit reached, trading paused |
| `Entry blocked:` | Signal filtered (spread, EMA, hours, news, daily limit) |

**Example of a full trade lifecycle:**
```
[REGIME] Switched to TRENDING (ADX=38.4 >= 30) — hidden divergence mode
[DIV] HIDDEN BULL BUY @ 1.17413 | RSI: 31.9 < ref 93.5 (bar 20) | price: 1.17399 > ref 1.17311 | SL: 1.17213 | TP: 1.17563
[EXIT] BUY closed | TAKE PROFIT | profit: +127.59 EUR | price: 1.17563
[PNL] trade: +127.59 EUR | day total: +127.59 EUR
```

**Daily summary** is printed at the end of each trading session:
```
[PNL] === DAILY SUMMARY 2026.05.08: +154.59 EUR ===
```

---

## Going Live

The EA was developed and tested on a **MetaQuotes demo account**. Before switching to a live account:

1. **Run demo for at least 3–4 weeks** to collect enough data across different market conditions (ranging weeks, trending weeks, news events)
2. **Review daily P&L** — look for consistency, not just the average. A strategy with avg +150 EUR/day but 30% negative days needs parameter review before going live
3. **Choose an ECN broker** (IC Markets, Pepperstone, Darwinex). ECN brokers route orders directly to the interbank market and earn from commissions — they have no incentive to trade against you. Avoid dealing-desk (B-book) brokers that may widen spreads or add slippage on consistently profitable accounts
4. **Connecting to a new broker in MT5:** File → Open Account → search broker name → enter login + password provided by the broker. The EA and presets work unchanged
5. **Start with reduced lot size** (0.1–0.3) for the first week live, then scale up once execution quality is confirmed

---

## Docker Quick Reference

```bash
# Start containers
docker compose up --build

# Stop containers
docker compose down

# Full reset (deletes Wine volume — MT5 must be reinstalled)
docker compose down -v

# View EA logs live
tail -f mt5/logs/$(date +%Y%m%d).log | grep -a "ENTRY\|EXIT\|PNL\|REGIME\|DIV"
```

**Troubleshooting:**

| Symptom | Fix |
|---|---|
| noVNC blank screen | Wait 30–60s for Wine/Xvfb to start |
| MT5 not installed | Open noVNC terminal and run `wine C:\\mt5setup.exe` |
| EA not trading | Check AutoTrading button is green in MT5 toolbar |
| Error 10027 | AutoTrading was disabled — re-enable in MT5 toolbar |
| "Spread too wide" in logs | Increase `InpMaxSpreadPoints` in the `.set` file |
| EA shows old init message | Recompile with F7 in MetaEditor — old `.ex5` binary is cached |
