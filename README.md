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
