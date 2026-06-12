# MT5 Docker

MetaTrader 5 running inside a Docker container (Wine + noVNC) — no Windows machine needed.

> **EA repo:** see [scalp-engine](https://github.com/gcassata74/scalp-engine) (private) for the Expert Advisor source code and presets.

---

## Requirements

- Docker Engine
- Docker Compose v2
- `scalp-engine` repo cloned as a sibling directory: `../scalp-engine/`

```bash
git clone git@github.com:gcassata74/mt5-docker.git
git clone git@github.com:gcassata74/scalp-engine.git   # private
```

---

## Quick Start

```bash
# Start
docker compose up --build

# Access MT5
http://localhost:8000   # noVNC browser UI
localhost:1234          # VNC client (optional)

# Stop
docker compose down

# Full reset (deletes Wine volume — MT5 must be reinstalled)
docker compose down -v
```

---

## Volume Mounts

| Host path | Container path | Purpose |
|---|---|---|
| `../scalp-engine/experts/` | MT5 Experts Downloads | EA source (`.mq5`) and compiled binary (`.ex5`) |
| `../scalp-engine/home/presets/` | MT5 Files/presets + `/home/presets` | `.set` parameter files per symbol |
| `./mt5/indicators/` | MT5 Indicators Downloads | Custom indicators |
| `./mt5/logs/` | MT5 Logs | Daily log files (`YYYYMMDD.log`) |

---

## First-time MT5 Install

MT5 is not bundled in the image. On first run, place the broker's `mt5setup.exe` in `mt5/mt5setup.exe` and rebuild, or install manually via VNC:

```bash
# Open VNC at http://localhost:8000, then in a terminal inside the container:
wine C:\\mt5setup.exe
```

---

## Compiling the EA

Open MetaEditor inside MT5 (Tools → MetaEditor), open `ScalpEngine_v3.mq5` from the Experts/Downloads folder, press **F7**. The `.ex5` binary is written to `../scalp-engine/experts/` automatically.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| noVNC blank screen | Wait 30–60s for Wine/Xvfb to start |
| MT5 not installed | Open noVNC and run `wine C:\\mt5setup.exe` |
| EA not trading | Check AutoTrading button is green in MT5 toolbar |
| Error 10027 | AutoTrading was disabled — re-enable in MT5 toolbar |
| EA shows old init message | Recompile with F7 in MetaEditor |

---

## View Logs Live

```bash
tail -f mt5/logs/$(date +%Y%m%d).log | grep -a "ENTRY\|EXIT\|PNL\|REGIME\|DIV"
```
