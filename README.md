# MT5 Docker

Docker image that runs MetaTrader 5 under Wine with a noVNC web interface — no Windows machine needed.

This repo contains only the infrastructure: Dockerfile, startup scripts, and supervisor config. It has no dependency on any specific EA or strategy.

---

## Usage

This image is intended to be used via `docker compose` from a project repo that provides the EA files and presets. Example `docker-compose.yml`:

```yaml
services:
  mt5:
    build:
      context: ../mt5-docker
      dockerfile: mt5/Dockerfile
    restart: unless-stopped
    ports:
      - "1234:1234"
      - "8000:8080"
    volumes:
      - mt5_config:/config
      - ./experts:/config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/Downloads
      - ./indicators:/config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Indicators/Downloads
      - ./home/presets:/config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/presets
      - ./logs:/config/.wine/drive_c/Program Files/MetaTrader 5/logs

volumes:
  mt5_config:
```

---

## Requirements

- Docker Engine
- Docker Compose v2
- A broker `mt5setup.exe` placed at `mt5/mt5setup.exe` before building (not included)

---

## First-time MT5 Install

MT5 is installed at first run. Place the broker installer at `mt5/mt5setup.exe` and run:

```bash
docker compose up --build
```

If the automatic install fails, open noVNC at `http://localhost:8000` and run manually:

```bash
wine C:\\mt5setup.exe
```

---

## Accessing MT5

| URL | Purpose |
|---|---|
| `http://localhost:8000` | noVNC browser UI |
| `localhost:1234` | VNC client (optional) |

---

## Graceful Shutdown

The container catches `SIGTERM` and closes MT5 cleanly (saves profiles/charts) before exiting. `stop_grace_period: 40s` is recommended in the compose file.

---

## Persistent Data

MT5 installation and settings are stored in a named Docker volume (`mt5_config`). EA files, presets, and logs are mounted from the host — they survive container rebuilds.

```bash
# Full reset (deletes Wine volume — MT5 must be reinstalled)
docker compose down -v
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| noVNC blank screen | Wait 30–60s for Wine/Xvfb to start |
| MT5 not installed | Open noVNC and run `wine C:\\mt5setup.exe` |
| EA not trading | Check AutoTrading button is green in MT5 toolbar |
| Error 10027 | AutoTrading was disabled — re-enable in MT5 toolbar |
