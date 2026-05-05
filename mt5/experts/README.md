# The RSI Engine v2.2 — MT5 Expert Advisor

**Automated forex scalping EA based on RSI slope divergence between price and RSI.**

---

## Strategy Overview

The RSI Engine detects divergence between the **linear regression slope of price** and the **linear regression slope of RSI**. When price and RSI move in opposite directions, the EA anticipates a price reversal and enters in the direction predicted by RSI.

### Core Logic

| Condition | Signal | Reasoning |
|---|---|---|
| Price slope bearish + RSI slope bullish | **BUY** | RSI leads — expect price to follow up |
| Price slope bullish + RSI slope bearish | **SELL** | RSI leads — expect price to follow down |

### Exit Logic

| Condition | Action |
|---|---|
| Price slope inverts to bullish (on a BUY) | Exit — divergence resolved with profit |
| Price slope inverts to bearish (on a SELL) | Exit — divergence resolved with profit |
| Both slopes align against the trade | Exit — signal failed, cut losses early |
| Take Profit hit | Exit fixed profit target |
| Stop Loss hit | Exit fixed protection |
| Break-even triggered | SL moved to entry price |
| Trailing stop triggered | SL follows price dynamically |

---

## Key Features

- **RSI Slope Divergence** — uses linear regression to detect divergence, identical logic to the *RSI Slope Divergence* indicator (14, 50)
- **Classic Swing Divergence** (optional) — traditional price/RSI swing high-low comparison
- **Slope Alignment Exit** — closes trades when divergence resolves, not just on fixed TP/SL
- **Break-Even Stop** — moves SL to entry price after a configurable profit threshold
- **Trailing Stop** — follows price tick-by-tick once profit target is reached
- **Daily Profit/Loss Limits** — stops trading when daily targets are hit
- **News Filter** — pauses entries around configurable news events
- **Trading Hours Filter** — restricts entries to specific sessions per weekday
- **Spread Filter** — blocks entries when spread exceeds maximum threshold
- **Risk Management** — optional dynamic lot sizing based on % equity risk per trade

---

## Parameters Reference

### Trade Management

| Parameter | Description | Default |
|---|---|---|
| `InpUseRiskManagement` | Enable dynamic lot sizing based on risk % | false |
| `InpRiskPercent` | % of equity to risk per trade (when enabled) | 1.0 |
| `InpLots` | Fixed lot size (when risk management is off) | 0.1 |
| `InpStopLossPoints` | Stop loss in points | 300 |
| `InpTakeProfitPoints` | Take profit in points | 300 |
| `InpMagicNumber` | Unique EA identifier — use different value per chart | 1901 |
| `InpMaxSpreadPoints` | Max allowed spread in points for new entries | 30 |

> On 5-digit brokers: 10 points = 1 pip. On EURUSD with 1 lot, 1 pip = ~$10.

### Trailing Stop

| Parameter | Description | Default |
|---|---|---|
| `InpUseTrailingStop` | Enable trailing stop | true |
| `InpUseBreakEven` | Move SL to break-even before trailing | true |
| `InpBreakEvenTrigger` | Profit in points to activate break-even (0 = SL value) | 0 |
| `InpTrailingStopTrigger` | Profit in points to start trailing | 3000 |
| `InpTrailingStopStep` | Trailing distance from current price in points | 50 |

### RSI Settings

| Parameter | Description | Default |
|---|---|---|
| `InpRSI_Period` | RSI calculation period | 14 |
| `InpRSI_Overbought` | Overbought level (set 100 to disable OB/OS filter) | 70 |
| `InpRSI_Oversold` | Oversold level (set 0 to disable OB/OS filter) | 30 |
| `InpRSI_Centerline` | Centerline for optional confirmation filter | 50 |

### Strategy Signals & Exits

| Parameter | Description | Default |
|---|---|---|
| `InpUse_Divergence_Signal` | Enable RSI divergence as entry signal | true |
| `InpUse_Classic_Divergence` | Use swing high/low divergence (false = slope mode) | true |
| `InpUse_OverboughtOversold_Reversal` | Enable OB/OS reversal as additional signal | true |
| `InpUse_Centerline_Confirmation` | Require RSI to cross centerline before entry | true |
| `InpUse_RSI_Level_Exit` | Exit when RSI reaches opposite extreme level | false |
| `InpUse_Slope_Alignment_Exit` | Exit when divergence resolves (recommended) | true |
| `InpDivergence_Lookback_Bars` | Bars to scan for classic swing divergence | 60 |
| `InpRequire_Slope_Divergence` | Require slope divergence as additional confirmation | false |
| `InpSlope_Lookback_Bars` | Linear regression period — match your indicator setting | 50 |
| `InpVerboseEntryLogs` | Print entry block reasons to Expert log | true |

---

## Recommended Setup (M5 Scalping)

Use the included `.set` preset files and attach the *RSI Slope Divergence* indicator with settings **(14, 50)** to visually confirm signals.

### Recommended Pairs — Low Correlation

| Pair | SL (pts) | TP (pts) | Break-Even (pts) | Trailing Trigger | Max Spread |
|---|---|---|---|---|---|
| EURUSD | 60 | 90 | 20 | 30 | 10 |
| USDJPY | 70 | 105 | 20 | 30 | 13 |
| EURGBP | 50 | 75 | 20 | 30 | 15 |

> **Important:** Do not run highly correlated pairs simultaneously (e.g. EURUSD + GBPUSD + AUDUSD). A single USD move triggers all of them at once, multiplying risk exposure.

### Correlation Guide

| Combination | Correlation | Verdict |
|---|---|---|
| EURUSD + USDJPY | ~+0.2 | Safe ✅ |
| EURUSD + EURGBP | ~+0.3 | Safe ✅ |
| EURUSD + GBPUSD | ~+0.65 | Avoid ❌ |
| EURUSD + USDCHF | ~-0.90 | Avoid ❌ |
| USDJPY + EURJPY | ~+0.80 | Avoid ❌ |

---

## Quick Start

1. Copy `The_RSI_Engine_v2.2.ex5` to `MT5/MQL5/Experts/`
2. Copy the *RSI Slope Divergence* indicator to `MT5/MQL5/Indicators/`
3. Open an M5 chart for your chosen pair
4. Attach the EA and load the corresponding `.set` preset from the `presets/` folder
5. Attach the *RSI Slope Divergence* indicator with period **(14, 50)** for visual confirmation
6. Enable **Algo Trading** in MT5 toolbar

---

## Version History

| Version | Changes |
|---|---|
| v2.2 | Slope alignment exit, break-even stop, OB/OS zone filter fix, signal-failed early exit |
| v2.1 | Critical bug fix: bullish/bearish slope signals were swapped |
| v2.0 | Initial release: slope divergence, trailing stop, daily limits, news filter, time filter |

---

## Risk Warning

Trading forex involves significant risk of loss. Past performance does not guarantee future results. Always test on a **demo account** before going live. This EA does not guarantee profits. Use appropriate risk management settings for your account size.

---

*Copyright 2025, SPLpulse — https://splpulse.com*
