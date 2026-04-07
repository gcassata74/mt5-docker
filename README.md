# MT5 Docker + noVNC (Linux)

This repository runs MetaTrader 5 inside a Docker container with a built-in
noVNC web UI so you can access the Windows app from a browser on Linux.

## What you get
- MT5 running under Wine in a container
- noVNC web access on `http://localhost:8000`
- VNC port exposed on `localhost:1234` (if you prefer a VNC client)
- Persistent Wine prefix stored in a Docker volume
- Convenient mounts for Experts and Indicators downloads

## Requirements
- Docker Engine
- Docker Compose v2

## Quick start
1) Build and start:
```bash
docker compose up --build
```

2) Open MT5 in your browser:
- noVNC: `http://localhost:8000`

3) First run install:
- The container tries to auto-install MT5 on first run.
- If MT5 doesn’t appear, open noVNC and run the installer manually:
  - Open a terminal inside the container UI and run:
    ```
    wine C:\\mt5setup.exe
    ```

## Ports
- `8000:8080` → noVNC web UI
- `1234:1234` → VNC (optional)

## Persistent data
- Wine prefix lives in Docker volume `mt5_config`
- Local mounts:
  - `./mt5/home` → `/home`
  - `./mt5/experts` → MT5 Experts Downloads
  - `./mt5/indicators` → MT5 Indicators Downloads

## Notes
- The MT5 installer executable is baked into the image at `mt5/mt5setup.exe`.
- MT5 is launched via `supervisord` after installation.
- CPU and memory limits are set in `docker-compose.yml` (`cpus: 3.0`, `mem_limit: 4g`, `shm_size: 1g`).

## Example `.set` (M5 Divergence Focus)
Current example file: `mt5/home/rsi_engine_m5_divergence_focus.set`

```ini
InpUseRiskManagement=true
InpRiskPercent=5.0
InpLots=0.1
InpStopLossPoints=100
InpTakeProfitPoints=220
InpMagicNumber=190106
InpMaxSpreadPoints=22
InpUseTrailingStop=true
InpTrailingStopTrigger=50
InpTrailingStopStep=25
InpRSI_Period=6
InpRSI_Overbought=78
InpRSI_Oversold=22
InpRSI_Centerline=50
InpUse_Divergence_Signal=true
InpUse_OverboughtOversold_Reversal=false
InpUse_Centerline_Confirmation=true
InpUse_RSI_Level_Exit=false
InpDivergence_Lookback_Bars=48
EnableDailyLimits=true
DailyProfitTarget=500.0
DailyLossLimit=1000.0
InpUseNewsFilter=false
InpNewsTimeHour=15
InpNewsTimeMinute=30
InpMinutesBeforeNews=10
InpMinutesAfterNews=10
EnableTimeFilter=false
MondayHours=16:30-18:00;09:00-11:00
TuesdayHours=16:30-18:00;09:00-11:00
WednesdayHours=16:30-18:00;09:00-11:00
ThursdayHours=16:30-18:00;09:00-11:00
FridayHours=16:30-18:00;09:00-11:00
SaturdayHours=00:00-00:00
SundayHours=00:00-00:00
CloseAtEndTime=false
```

### Parameter table and units

Important:
- On most 5-digit Forex symbols, `10 points = 1 pip`.
- EUR equivalence for points/pips depends on symbol, lot size, and account currency.
- For EURUSD, approx pip value is:
  - `1.0 lot ~= 10 EUR/pip`
  - `0.1 lot ~= 1 EUR/pip`
  - `0.01 lot ~= 0.10 EUR/pip`

| Parameter | Value | Unit | Meaning | Quick EUR example |
|---|---:|---|---|---|
| `InpUseRiskManagement` | `true` | bool | Dynamic lot sizing by risk % | If `false`, `InpLots` is used |
| `InpRiskPercent` | `5.0` | % equity | Risk per trade (when enabled) | On 10,000 EUR equity, nominal risk target is 500 EUR |
| `InpLots` | `0.1` | lots | Fixed lot size (only if risk mgmt is off) | On EURUSD, ~1 EUR/pip |
| `InpStopLossPoints` | `100` | points (~10 pips) | Stop loss distance | At 0.1 lot EURUSD: ~10 EUR |
| `InpTakeProfitPoints` | `220` | points (~22 pips) | Take profit distance | At 0.1 lot EURUSD: ~22 EUR |
| `InpMagicNumber` | `190106` | id | Unique EA trade identifier | N/A |
| `InpMaxSpreadPoints` | `22` | points (~2.2 pips) | Max spread allowed for new entries | At 0.1 lot EURUSD spread cost ~2.2 EUR |
| `InpUseTrailingStop` | `true` | bool | Enable trailing stop logic | N/A |
| `InpTrailingStopTrigger` | `50` | points (~5 pips) | Profit needed before trailing starts | At 0.1 lot EURUSD: ~5 EUR unrealized |
| `InpTrailingStopStep` | `25` | points (~2.5 pips) | Trailing distance from price | At 0.1 lot EURUSD: ~2.5 EUR buffer |
| `InpRSI_Period` | `6` | bars | RSI speed/sensitivity | N/A |
| `InpRSI_Overbought` | `78` | RSI level | Overbought threshold | N/A |
| `InpRSI_Oversold` | `22` | RSI level | Oversold threshold | N/A |
| `InpRSI_Centerline` | `50` | RSI level | RSI centerline for optional confirmation | N/A |
| `InpUse_Divergence_Signal` | `true` | bool | Use RSI divergence entries | N/A |
| `InpUse_OverboughtOversold_Reversal` | `false` | bool | Disable OB/OS reversal entries | N/A |
| `InpUse_Centerline_Confirmation` | `true` | bool | Require centerline confirmation | N/A |
| `InpUse_RSI_Level_Exit` | `false` | bool | Exit by RSI levels disabled | N/A |
| `InpDivergence_Lookback_Bars` | `48` | bars | Bars used to detect divergence | On M5, ~4 hours window |
| `EnableDailyLimits` | `true` | bool | Enable daily stop rules | N/A |
| `DailyProfitTarget` | `500.0` | deposit currency (EUR if account is EUR) | Stop trading for day after hitting profit | +500 EUR/day stop |
| `DailyLossLimit` | `1000.0` | deposit currency (EUR if account is EUR) | Stop trading for day after hitting loss | -1000 EUR/day stop |
| `InpUseNewsFilter` | `false` | bool | Disable fixed-time news block | N/A |
| `InpNewsTimeHour` | `15` | hour (server time) | News event hour | N/A |
| `InpNewsTimeMinute` | `30` | minute (server time) | News event minute | N/A |
| `InpMinutesBeforeNews` | `10` | minutes | Block entries before news | N/A |
| `InpMinutesAfterNews` | `10` | minutes | Block entries after news | N/A |
| `EnableTimeFilter` | `false` | bool | Disable session hour filter | N/A |
| `MondayHours` | `16:30-18:00;09:00-11:00` | server-time sessions | Allowed Monday sessions | N/A |
| `TuesdayHours` | `16:30-18:00;09:00-11:00` | server-time sessions | Allowed Tuesday sessions | N/A |
| `WednesdayHours` | `16:30-18:00;09:00-11:00` | server-time sessions | Allowed Wednesday sessions | N/A |
| `ThursdayHours` | `16:30-18:00;09:00-11:00` | server-time sessions | Allowed Thursday sessions | N/A |
| `FridayHours` | `16:30-18:00;09:00-11:00` | server-time sessions | Allowed Friday sessions | N/A |
| `SaturdayHours` | `00:00-00:00` | server-time sessions | Disabled session | N/A |
| `SundayHours` | `00:00-00:00` | server-time sessions | Disabled session | N/A |
| `CloseAtEndTime` | `false` | bool | Do not force close at end of session | N/A |

### USDJPY starter set and 400 EUR/day target

If you want to work toward a daily target around `400` (account currency), use:
- `mt5/home/rsi_engine_m5_usdjpy_focus.set`
- `DailyProfitTarget=400.0`
- `DailyLossLimit=800.0` (example 1:2 reward/risk day cap)

Important:
- If `InpUseRiskManagement=true`, `InpLots` is ignored.
- `InpLots` matters only when `InpUseRiskManagement=false`.

Quick reference for the USDJPY starter (`InpStopLossPoints=120` = ~12 pips):

| Fixed lots (`InpUseRiskManagement=false`) | Approx pip value (USDJPY) | Approx SL risk at 12 pips |
|---:|---:|---:|
| `0.1` | `~0.67 USD/pip` | `~8 USD` |
| `0.3` | `~2.0 USD/pip` | `~24 USD` |
| `0.5` | `~3.3 USD/pip` | `~40 USD` |
| `1.0` | `~6.7 USD/pip` | `~80 USD` |

These values are approximate and vary with price and account currency conversion.

## Stop
```bash
docker compose down
```

## Troubleshooting
- If noVNC shows a blank screen, wait 30–60 seconds for Wine/Xvfb to settle.
- If MT5 didn’t install, run `wine C:\\mt5setup.exe` in the noVNC desktop.
- If you need a fresh install, remove the volume:
  ```
  docker compose down -v
  ```
